#!/bin/sh
# Sync the *entire* boot/ tree from raspberrypi/firmware into /tftpboot
set -euo pipefail

echo "=== Downloading Raspberry Pi Boot Files ==="

TFTP_DIR="${OUTPUT_DIR:-/tftpboot}"   # <— use OUTPUT_DIR consistently
mkdir -p "$TFTP_DIR"

# tools (container is Alpine)
if ! command -v git >/dev/null 2>&1; then
  apk add --no-cache git
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Sparse checkout just the boot/ directory
git -C "$TMPDIR" init -q
git -C "$TMPDIR" remote add origin https://github.com/raspberrypi/firmware.git
git -C "$TMPDIR" config core.sparseCheckout true
git -C "$TMPDIR" sparse-checkout set boot
git -C "$TMPDIR" pull --depth=1 origin master -q

# Copy/refresh
if ! command -v rsync >/devn/null 2>&1; then
  apk add --no-cache rsync
fi

rsync -a --delete "$TMPDIR/boot/" "$TFTP_DIR/"

# Write our Pi 5 config + cmdline (overrides whatever the repo had)
cat > "$TFTP_DIR/config.txt" <<'EOF'
# Pi 5 network boot first stage (kernel + DTB + optional initramfs)
[all]
arm_64bit=1
kernel=kernel8.img
# If you want to be explicit, keep this; Pi usually auto-selects:
device_tree=bcm2712-rpi-5-b.dtb
# Our slim RAM installer (you will place this file):
initramfs initramfs8 followkernel

enable_uart=1
gpu_mem=16
# os_check=0   # optional while aligning kernel/DTB
EOF

cat > "$TFTP_DIR/cmdline.txt" <<'EOF'
console=serial0,115200 console=tty1 ip=dhcp root=/dev/ram0 rw rdinit=/init
EOF

# Permissions for tftpd --secure
chmod a+rx "$TFTP_DIR"
find "$TFTP_DIR" -type d -exec chmod a+rx {} \;
find "$TFTP_DIR" -type f -exec chmod a+r  {} \;

echo "=== Boot Files Download Complete ==="
ls -lah "$TFTP_DIR"