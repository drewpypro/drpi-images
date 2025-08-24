#!/bin/sh
# scripts/download-boot-files.sh
# Downloads essential Pi boot files from Raspberry Pi firmware repo

set -e

echo "=== Downloading Raspberry Pi Boot Files ==="

# Install wget if not available
apk add --no-cache wget curl

TFTP_DIR="${OUTPUT_DIR:-/tftpboot}"
mkdir -p "$TFTP_DIR"
cd "$TFTP_DIR"

# Clone/sync only the 'boot' directory from the firmware repo
# Using git sparse-checkout is cleaner than wget’ing each file
TMPDIR=$(mktemp -d)
git clone --depth=1 --filter=blob:none --sparse https://github.com/raspberrypi/firmware.git "$TMPDIR"
cd "$TMPDIR"
git sparse-checkout set boot

echo "✓ Cloned firmware repo boot/ folder"

# Copy boot files into TFTP directory
cp -av boot/* "$TFTP_DIR/"
cd "$TFTP_DIR"
rm -rf "$TMPDIR"

# Create basic config files
echo "Creating basic configuration files..."

# Basic config.txt for Pi 5
cat > config.txt << 'EOF'
[all]
arm_64bit=1

kernel=kernel8.img
initramfs initramfs.cpio.gz followkernel

# Enable UART for debugging
enable_uart=1

# GPU memory split (minimal for headless)
gpu_mem=16

# Network boot specific
#dtparam=sd_poll_once=on

# USB boot fallback
#program_usb_boot_mode=1
EOF

# Basic cmdline.txt - will be overridden by our initramfs builder
cat > cmdline.txt << 'EOF'
console=ttyS0,115200 console=tty1 root=/dev/ram0 init=/init quiet
EOF

# Set permissions
chmod 644 *

echo ""
echo "=== Boot Files Download Complete ==="
echo "Files in TFTP directory:"
ls -la /output/
echo ""
echo "✓ Ready for initramfs build step"