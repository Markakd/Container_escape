#!/usr/bin/env bash
set -Eeuo pipefail

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$VM_DIR/config.env"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

for command in curl qemu-img qemu-system-x86_64 sha256sum ssh \
    ssh-keygen xorriso; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

[[ "$VM_BUILD_SSH_PORT" =~ ^[0-9]+$ ]] &&
    (( VM_BUILD_SSH_PORT >= 1 && VM_BUILD_SSH_PORT <= 65535 )) ||
    die "VM_BUILD_SSH_PORT must be between 1 and 65535"

BUILD_DIR="$(mktemp -d "$VM_DIR/.build.XXXXXX")"
IMAGE_NAME="${UBUNTU_IMAGE_URL##*/}"
SOURCE_IMAGE="$BUILD_DIR/$IMAGE_NAME"
WORK_IMAGE="$BUILD_DIR/ubuntu-work.qcow2"
SEED_DIR="$BUILD_DIR/seed"
SEED_ISO="$BUILD_DIR/seed.iso"
SERIAL_LOG="$BUILD_DIR/serial.log"
QEMU_LOG="$BUILD_DIR/qemu.log"
QEMU_PID=""

cleanup() {
    if [[ "$QEMU_PID" =~ ^[0-9]+$ ]] &&
        kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    case "$BUILD_DIR" in
        "$VM_DIR"/.build.*) rm -rf -- "$BUILD_DIR" ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$(dirname -- "$SSH_KEY")" "$SEED_DIR"
if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$BUILD_DIR/new-id_ed25519"
    mv -- "$BUILD_DIR/new-id_ed25519" "$SSH_KEY"
fi
chmod 0600 "$SSH_KEY"
public_key="$(ssh-keygen -y -f "$SSH_KEY")"

printf 'Downloading Ubuntu %s cloud image...\n' "$UBUNTU_VERSION" >&2
curl -fL --retry 3 --progress-bar "$UBUNTU_IMAGE_URL" -o "$SOURCE_IMAGE"

(
    cd "$BUILD_DIR"
    curl -fsSL "$UBUNTU_SUMS_URL" |
        sha256sum --ignore-missing -c -
)

qemu-img convert -q -O qcow2 "$SOURCE_IMAGE" "$WORK_IMAGE"
qemu-img resize -q "$WORK_IMAGE" 16G

cat >"$SEED_DIR/meta-data" <<EOF
instance-id: ubuntu-container-builder
local-hostname: ubuntu-container
EOF

cat >"$SEED_DIR/user-data" <<EOF
#cloud-config
users:
  - name: $VM_USER
    gecos: Ubuntu container runner
    shell: /bin/bash
    groups: [adm, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: true
packages:
  - docker.io
runcmd:
  - [systemctl, enable, --now, docker]
EOF

xorriso -as mkisofs -quiet -volid cidata -joliet -rock \
    -o "$SEED_ISO" "$SEED_DIR/user-data" "$SEED_DIR/meta-data"

accel=(-accel tcg -cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel=(-accel kvm -cpu host)
fi

qemu-system-x86_64 \
    -name ubuntu-container-builder \
    -machine "$VM_MACHINE" \
    "${accel[@]}" \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY_MB" \
    -nodefaults \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -device virtio-rng-pci \
    -drive "if=virtio,format=qcow2,file=$WORK_IMAGE" \
    -drive "if=virtio,format=raw,readonly=on,file=$SEED_ISO" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_BUILD_SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -no-reboot \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

ssh_options=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

guest_ssh() {
    ssh -n "${ssh_options[@]}" -p "$VM_BUILD_SSH_PORT" \
        "$VM_USER@127.0.0.1" "$@"
}

printf 'Provisioning Ubuntu %s and Docker...\n' "$UBUNTU_VERSION" >&2
deadline=$((SECONDS + VM_BUILD_TIMEOUT))
until guest_ssh true >/dev/null 2>&1; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        sed -n '1,120p' "$QEMU_LOG" >&2
        tail -n 120 "$SERIAL_LOG" >&2 || true
        die "Provisioning VM exited before SSH became available"
    fi
    (( SECONDS < deadline )) ||
        die "Timed out waiting for provisioning VM SSH"
    sleep 2
done

guest_ssh 'cloud-init status --wait'
guest_ssh "sudo docker pull $(printf '%q' "$DOCKER_IMAGE")"
guest_ssh 'sudo fstrim -av || true'

kernel="$(guest_ssh 'basename "$(ls /boot/vmlinuz-* | sort -V | tail -n 1)"')"
kernel="${kernel#vmlinuz-}"
if [[ -n "$VM_EXPECTED_KERNEL" && "$kernel" != "$VM_EXPECTED_KERNEL" ]]; then
    die "Expected kernel $VM_EXPECTED_KERNEL, installed $kernel"
fi

guest_ssh 'sudo poweroff' >/dev/null 2>&1 || true
deadline=$((SECONDS + VM_SHUTDOWN_TIMEOUT))
while kill -0 "$QEMU_PID" 2>/dev/null; do
    (( SECONDS < deadline )) ||
        die "Provisioning VM did not shut down cleanly"
    sleep 1
done
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

output="$BUILD_DIR/ubuntu-final.qcow2"
qemu-img convert -q -O qcow2 -c "$WORK_IMAGE" "$output"
mv -f -- "$output" "$GOLDEN_IMAGE"
chmod 0444 "$GOLDEN_IMAGE"

printf 'Built %s with Ubuntu kernel %s\n' "$GOLDEN_IMAGE" "$kernel"
