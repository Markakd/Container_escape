# Disposable Ubuntu container VM

This directory builds and runs an Ubuntu Docker container inside a disposable Ubuntu QEMU guest. PoCs are copied into the guest and are never executed by the host scripts.

## Host dependencies

- Bash
- QEMU x86-64 and `qemu-img`
- `curl`
- OpenSSH client tools
- `xorriso`
- `socat` only when `VM_PAYLOAD_CONSOLE=1` is used

KVM is used when available; otherwise QEMU falls back to TCG.

## Build a golden image

```sh
UBUNTU_VERSION=26.04 \
VM_EXPECTED_KERNEL=7.0.0-31-generic \
./vm/build_image.sh
```

The builder downloads the selected Ubuntu release cloud image, validates it against Ubuntu's published `SHA256SUMS`, installs package updates and Docker, pulls the matching Ubuntu container image, and writes `vm/ubuntu-<version>.qcow2`.

The default URLs are pinned to the latest official release images available on September 16, 2026:

- Ubuntu 24.04: release serial `20260911`
- Ubuntu 26.04: release serial `20260823`

Set `UBUNTU_RELEASE_URL`, `UBUNTU_IMAGE_URL`, or `UBUNTU_SUMS_URL` to use another release.

The generated qcow2 image and SSH key are local artifacts ignored by Git. The private key remains mode `0600`.

## Run a binary

```sh
UBUNTU_VERSION=26.04 \
VM_EXPECTED_KERNEL=7.0.0-31-generic \
./vm/run_container.sh ./path/to/binary [arguments...]
```

Each run creates a temporary qcow2 overlay, boots the guest, copies the binary over SSH, and launches it in a fresh container with networking disabled. Arguments, standard streams, and the exit status are forwarded.

Useful overrides:

```sh
VM_CPUS=4 VM_MEMORY_MB=4096 ./vm/run_container.sh ./binary
VM_SSH_PORT=2223 ./vm/run_container.sh ./binary
KEEP_VM_RUN_DIR=1 ./vm/run_container.sh ./binary
```

`KEEP_VM_RUN_DIR=1` retains the overlay and logs under `/tmp/ubuntu-container.*`. Each invocation performs one VM boot and one payload attempt. Set `VM_PAYLOAD_CONSOLE=1` for a payload that explicitly uses the guest's second serial port.
