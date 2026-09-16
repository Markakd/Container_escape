# Linux container escape PoCs

Target-specific proof-of-concept exploits for two Linux kernel vulnerabilities:

| CVE | Subsystem | Tested guest |
| --- | --- | --- |
| CVE-2026-52910 | reuseport classic BPF | Ubuntu 24.04, `6.8.0-139-generic` |
| CVE-2026-80521 | AF_UNIX garbage collection | Ubuntu 26.04, `7.0.0-31-generic` |

These PoCs are destructive kernel exploits. Use them only for authorized research inside the disposable VM environment. Never execute a PoC directly on a workstation, server, or container host.

## Repository layout

```text
.
|-- pocs/
|   |-- CVE-2026-52910/
|   `-- CVE-2026-80521/
`-- vm/
```

Compiled binaries, VM disk images, generated SSH keys, logs, and local kernel artifacts are intentionally excluded from version control.

## Build the PoCs

The default build produces static x86-64 binaries:

```sh
make
```

Install a C compiler, GNU Make, and the static libc development files if the linker cannot satisfy `-static`.

## Build the disposable VMs

The VM builder needs QEMU, `qemu-img`, `curl`, OpenSSH, `xorriso`, and `sha256sum`. It downloads the selected Ubuntu cloud image, verifies its published checksum, installs updates and Docker, and creates a read-only golden qcow2 image.

Build each target separately:

```sh
UBUNTU_VERSION=24.04 \
VM_EXPECTED_KERNEL=6.8.0-139-generic \
./vm/build_image.sh

UBUNTU_VERSION=26.04 \
VM_EXPECTED_KERNEL=7.0.0-31-generic \
./vm/build_image.sh
```

The cloud-image URLs are pinned in `vm/config.env`. The build stops if package provisioning no longer produces the expected target kernel. Override `UBUNTU_RELEASE_URL`, `UBUNTU_IMAGE_URL`, or `UBUNTU_SUMS_URL` to use another release.

## Run

Run the binaries only through the matching VM:

```sh
UBUNTU_VERSION=24.04 \
VM_EXPECTED_KERNEL=6.8.0-139-generic \
VM_PAYLOAD_CONSOLE=1 \
./vm/run_container.sh ./pocs/CVE-2026-52910/poc

UBUNTU_VERSION=26.04 \
VM_EXPECTED_KERNEL=7.0.0-31-generic \
./vm/run_container.sh ./pocs/CVE-2026-80521/poc
```

Each invocation creates a temporary overlay, starts a fresh Docker container inside the guest, forwards terminal I/O, and removes the overlay afterward. See [vm/README.md](vm/README.md) and each PoC directory for target-specific details.
