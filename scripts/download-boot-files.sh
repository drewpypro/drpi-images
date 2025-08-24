#!/bin/sh
# scripts/download-boot-files.sh
# Downloads essential Pi boot files from Raspberry Pi firmware repo

set -e

echo "=== Downloading Raspberry Pi Boot Files ==="

# Install wget if not available
apk add --no-cache wget curl

cd ${OUTPUT_FILE:-/tftpboot}

# Base URL for Pi firmware
FIRMWARE_BASE="https://github.com/raspberrypi/firmware/raw/master/boot"

echo "Downloading Pi bootloader files..."

# Essential boot files for Pi 5
wget -O bootcode.bin "$FIRMWARE_BASE/bootcode.bin"
echo "✓ Downloaded bootcode.bin"

wget -O start4.elf "$FIRMWARE_BASE/start4.elf"  
echo "✓ Downloaded start4.elf"

wget -O fixup4.dat "$FIRMWARE_BASE/fixup4.dat"
echo "✓ Downloaded fixup4.dat"

wget -O "$DTB_FILE" "$FIRMWARE_BASE/$DTB_FILE" 
echo "✓ Downloaded $DTB_FILE"

# Pi 5 specific files
wget -O start4cd.elf "$FIRMWARE_BASE/start4cd.elf" || echo "⚠ start4cd.elf not found (optional)"
wget -O fixup4cd.dat "$FIRMWARE_BASE/fixup4cd.dat" || echo "⚠ fixup4cd.dat not found (optional)"


# Get a basic kernel (we'll replace with custom later)
wget -O kernel8.img "$FIRMWARE_BASE/kernel8.img"
echo "✓ Downloaded kernel8.img"

# Create basic config files
echo "Creating basic configuration files..."

# Basic config.txt for Pi 5
cat > config.txt << 'EOF'
# Pi 5 Network Boot Configuration
[pi5]
kernel=kernel8.img
initramfs initramfs8 followkernel

# Enable UART for debugging
enable_uart=1

# GPU memory split (minimal for headless)
gpu_mem=16

# Network boot specific
dtparam=sd_poll_once=on

# USB boot fallback
program_usb_boot_mode=1
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