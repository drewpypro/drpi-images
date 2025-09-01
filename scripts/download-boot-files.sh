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
if ! command -v rsync >/dev/null 2>&1; then
  apk add --no-cache rsync
fi

rsync -a --delete "$TMPDIR/boot/" "$TFTP_DIR/"

# Write our Pi 5 config + cmdline (overrides whatever the repo had)
cat > "$TFTP_DIR/config.txt" <<'EOF'
# Pi 5 network boot configuration
[all]
arm_64bit=1
kernel=kernel8.img
initramfs initramfs8 followkernel
device_tree=bcm2712-rpi-5-b.dtb

enable_uart=1
gpu_mem=16

# Disable firmware debug
uart_2ndstage=0
EOF

cat > "$TFTP_DIR/cmdline.txt" <<'EOF'
console=serial0,115200 console=tty1 ip=dhcp rootwait rw
EOF

# Permissions for tftpd --secure
chmod a+rx "$TFTP_DIR"
find "$TFTP_DIR" -type d -exec chmod a+rx {} \;
find "$TFTP_DIR" -type f -exec chmod a+r  {} \;

echo "=== Boot Files Download Complete ==="
ls -lah "$TFTP_DIR"