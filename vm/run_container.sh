#!/usr/bin/env bash
set -Eeuo pipefail

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$VM_DIR/config.env"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if (( $# == 0 )); then
    printf 'Usage: %s /path/to/binary [arguments...]\n' \
        "$(basename "$0")" >&2
    exit 2
fi

BINARY="$(realpath -e -- "$1")" ||
    die "Binary not found: $1"
[[ -f "$BINARY" && -x "$BINARY" ]] ||
    die "Binary must be an executable file: $BINARY"
shift

for path in "$GOLDEN_IMAGE" "$SSH_KEY"; do
    [[ -r "$path" ]] ||
        die "Missing $path. Run $VM_DIR/build_image.sh first."
done
for command in qemu-img qemu-system-x86_64 scp ssh; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

case "$VM_PAYLOAD_CONSOLE" in
    0) ;;
    1)
        command -v socat >/dev/null 2>&1 ||
            die "Required command not found: socat"
        ;;
    *) die "VM_PAYLOAD_CONSOLE must be 0 or 1" ;;
esac

[[ "$VM_SSH_PORT" =~ ^[0-9]+$ ]] &&
    (( VM_SSH_PORT >= 1 && VM_SSH_PORT <= 65535 )) ||
    die "VM_SSH_PORT must be between 1 and 65535"

RUN_DIR="$(mktemp -d /tmp/ubuntu-container.XXXXXX)"
OVERLAY="$RUN_DIR/root.qcow2"
SERIAL_LOG="$RUN_DIR/serial.log"
QEMU_LOG="$RUN_DIR/qemu.log"
PAYLOAD_SOCKET="$RUN_DIR/payload.sock"
RUN_SSH_KEY="$RUN_DIR/id_ed25519"
QEMU_PID=""
SSH_PID=""
CONSOLE_PID=""

cleanup() {
    local pid

    for pid in "$CONSOLE_PID" "$SSH_PID" "$QEMU_PID"; do
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done

    if [[ "${KEEP_VM_RUN_DIR:-0}" == 1 ]]; then
        printf 'VM diagnostics retained in %s\n' "$RUN_DIR" >&2
    else
        case "$RUN_DIR" in
            /tmp/ubuntu-container.*) rm -rf -- "$RUN_DIR" ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

qemu-img create -q -f qcow2 -F qcow2 \
    -b "$GOLDEN_IMAGE" "$OVERLAY"
cp -- "$SSH_KEY" "$RUN_SSH_KEY"
chmod 0600 "$RUN_SSH_KEY"

accel=(-accel tcg -cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel=(-accel kvm -cpu host)
fi

console_args=()
if (( VM_PAYLOAD_CONSOLE )); then
    console_args=(
        -chardev "socket,id=payload,path=$PAYLOAD_SOCKET,server=on,wait=off"
        -device isa-serial,chardev=payload,index=1
    )
fi

qemu-system-x86_64 \
    -name "ubuntu-container-${RUN_DIR##*.}" \
    -machine "$VM_MACHINE" \
    "${accel[@]}" \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY_MB" \
    -nodefaults \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -device virtio-rng-pci \
    "${console_args[@]}" \
    -drive "if=virtio,format=qcow2,file=$OVERLAY" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -no-reboot \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

ssh_options=(
    -i "$RUN_SSH_KEY"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

vm_ssh() {
    ssh -n "${ssh_options[@]}" -p "$VM_SSH_PORT" \
        "$VM_USER@127.0.0.1" "$@"
}

printf 'Booting Ubuntu %s...\n' "$UBUNTU_VERSION" >&2
deadline=$((SECONDS + VM_BOOT_TIMEOUT))
until vm_ssh true >/dev/null 2>&1; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        sed -n '1,120p' "$QEMU_LOG" >&2
        die "QEMU exited before SSH became available"
    fi
    if (( SECONDS >= deadline )); then
        tail -n 120 "$SERIAL_LOG" >&2 || true
        die "Timed out waiting for Ubuntu SSH"
    fi
    sleep 2
done

running_kernel="$(vm_ssh uname -r)"
if [[ -n "$VM_EXPECTED_KERNEL" &&
      "$running_kernel" != "$VM_EXPECTED_KERNEL" ]]; then
    die "Expected kernel $VM_EXPECTED_KERNEL, booted $running_kernel"
fi

job_id="run-$$-$RANDOM"
remote_binary="/tmp/$job_id"
scp -q "${ssh_options[@]}" -P "$VM_SSH_PORT" \
    "$BINARY" "$VM_USER@127.0.0.1:$remote_binary"
vm_ssh "chmod 0755 $(printf '%q' "$remote_binary")"

docker_flags=(--rm -i)
ssh_tty=()
if (( ! VM_PAYLOAD_CONSOLE )) && [[ -t 0 && -t 1 ]]; then
    docker_flags=(--rm -it)
    ssh_tty=(-t)
fi

remote_command=(
    sudo docker run
    "${docker_flags[@]}"
    --network none
    --name "$job_id"
    --volume "$remote_binary:/payload:ro"
    "$DOCKER_IMAGE"
    /payload
    "$@"
)
printf -v remote_command_q '%q ' "${remote_command[@]}"

printf 'Running %s in %s on kernel %s...\n' \
    "$BINARY" "$DOCKER_IMAGE" "$running_kernel" >&2

set +e
if (( ! VM_PAYLOAD_CONSOLE )); then
    ssh "${ssh_options[@]}" "${ssh_tty[@]}" -p "$VM_SSH_PORT" \
        "$VM_USER@127.0.0.1" "$remote_command_q"
    status=$?
else
    ssh -n "${ssh_options[@]}" -p "$VM_SSH_PORT" \
        "$VM_USER@127.0.0.1" "$remote_command_q" &
    SSH_PID=$!

    if [[ -t 0 && -t 1 ]]; then
        socat STDIO,raw,echo=0 "UNIX-CONNECT:$PAYLOAD_SOCKET" <&0 >&1 &
    else
        socat STDIO "UNIX-CONNECT:$PAYLOAD_SOCKET" <&0 >&1 &
    fi
    CONSOLE_PID=$!

    wait -n -p completed_pid "$SSH_PID" "$CONSOLE_PID"
    first_status=$?
    if [[ "$completed_pid" == "$SSH_PID" ]]; then
        status=$first_status
        kill "$CONSOLE_PID" 2>/dev/null || true
        wait "$CONSOLE_PID" 2>/dev/null || true
    else
        wait "$SSH_PID"
        status=$?
    fi
    SSH_PID=""
    CONSOLE_PID=""
fi

if (( VM_PAYLOAD_CONSOLE )) &&
    grep -Fq 'RUN_CONTAINER_PAYLOAD_COMPLETE' "$SERIAL_LOG"; then
    status=0
fi
set -e

exit "$status"
