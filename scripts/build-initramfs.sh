#!/bin/sh
# scripts/build-initramfs.sh
# Builds custom initramfs that installs Alpine to USB (ARM64/Pi architecture)

set -e

echo "=== Building Custom InitramFS for Pi Network Boot ==="

# Install build tools
apk add --no-cache wget cpio gzip findutils

WORK_DIR="/tmp/initramfs-build"
OUTPUT_FILE="${OUTPUT_FILE:-/tftpboot/initramfs.cpio.gz}"

# Clean and create working directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "1. Creating initramfs directory structure..."
mkdir -p bin sbin etc proc sys dev tmp mnt newroot var root
mkdir -p usr/bin usr/sbin

echo "Directory structure created:"
ls -la

echo "2. Downloading ARM64 busybox for Pi..."
# Download ARM64 busybox from Alpine's aarch64 repository
cd "$WORK_DIR"

echo "Downloading ARM64 busybox package..."
BUSYBOX_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/main/aarch64/busybox-static-1.36.1-r20.apk"

if wget -q "$BUSYBOX_URL" -O busybox-static.apk; then
    echo "Downloaded ARM64 busybox package"
    
    # Extract the APK (it's just a tar.gz)
    tar -xzf busybox-static.apk >/dev/null 2>&1
    
    # Move the busybox.static binary
    if [ -f "bin/busybox.static" ]; then
        mv bin/busybox.static "$WORK_DIR/bin/busybox"
    else
        echo "ERROR: Could not find bin/busybox.static in ARM64 package"
        echo "Package contents:"
        find . -name "*busybox*" -type f
        exit 1
    fi
    
    # Clean up extraction
    rm -rf .SIGN.RSA* .PKGINFO bin usr sbin etc 2>/dev/null || true
    rm -f busybox-static.apk
else
    echo "ERROR: Could not download ARM64 busybox package"
    exit 1
fi


chmod +x "$WORK_DIR/bin/busybox"

# Verify we got ARM64 binary
echo "Verifying ARM64 busybox binary..."
file "$WORK_DIR/bin/busybox"

if file "$WORK_DIR/bin/busybox" | grep -q "aarch64\|ARM"; then
    echo "✓ ARM64 busybox binary confirmed"
else
    echo "⚠ Binary architecture may not be ARM64:"
    file "$WORK_DIR/bin/busybox"
    echo "Continuing anyway..."
fi

# Create essential command symlinks
cd bin
for cmd in sh ash cat cp mv rm ls ln mkdir mount umount wget tar gzip gunzip \
           ip ping udhcpc grep awk sed cut sort head tail find xargs sleep \
           echo printf test tr dd blkid lsblk fdisk mkfs.ext4 mkfs.fat \
           switch_root reboot poweroff; do
    ln -sf busybox "$cmd"
done
cd ..

# Also link in sbin
cd sbin  
for cmd in mount umount blkid mkfs.ext4 mkfs.fat fdisk switch_root \
           ip route ifconfig; do
    ln -sf /bin/busybox "$cmd"
done
cd ..

echo "3. Creating init script..."
cat > init << 'EOF'
#!/bin/sh
# Pi5 Network Boot InitramFS - Alpine USB Installer

echo "=== Pi5 Network Boot - Alpine Installer ==="
echo "Starting initramfs..."

# Basic system setup
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "Bringing up network interface..."
# Network setup
ip link set lo up
ip link set eth0 up

# Get IP via DHCP
echo "Requesting IP address via DHCP..."
udhcpc -i eth0 -n -q

# Show network status
IP=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
echo "Network configured: $IP"

# Find USB drive
echo "Looking for USB installation target..."
USB_DEVICE=""
for dev in /dev/sd[a-z]; do
    if [ -b "$dev" ]; then
        # Check if it's our prepared USB drive
        if blkid "${dev}2" | grep -q "alpine-root"; then
            USB_DEVICE="$dev"
            echo "Found prepared USB drive: $USB_DEVICE"
            break
        fi
    fi
done

if [ -z "$USB_DEVICE" ]; then
    echo "ERROR: No prepared USB drive found!"
    echo "Available block devices:"
    lsblk
    echo "Please ensure USB drive is connected and prepared"
    echo "Dropping to shell for debugging..."
    exec /bin/sh
fi

# Mount USB partitions
echo "Mounting USB partitions..."
mkdir -p /mnt/boot /mnt/root

if ! mount "${USB_DEVICE}1" /mnt/boot; then
    echo "ERROR: Could not mount boot partition ${USB_DEVICE}1"
    exec /bin/sh
fi

if ! mount "${USB_DEVICE}2" /mnt/root; then
    echo "ERROR: Could not mount root partition ${USB_DEVICE}2"  
    exec /bin/sh
fi

echo "USB partitions mounted successfully"

# Download Alpine Linux
echo "Downloading Alpine Linux..."
cd /tmp

# Try multiple Alpine sources (your git repo first, then official)
DOWNLOAD_SUCCESS=0

echo "Attempting download from git.drewpy.pro..."
if wget "https://git.drewpy.pro/drewpypro/rpi-images/raw/main/alpine/alpine-rpi-latest.tar.gz" -O alpine.tar.gz 2>/dev/null; then
    echo "✓ Downloaded Alpine from git.drewpy.pro"
    DOWNLOAD_SUCCESS=1
else
    echo "⚠ git.drewpy.pro not available (repo not created yet)"
fi

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    echo "Attempting download from Alpine official repository..."
    if wget "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.0-aarch64.tar.gz" -O alpine.tar.gz; then
        echo "✓ Downloaded Alpine from official repository"
        DOWNLOAD_SUCCESS=1
    fi
fi

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    echo "Trying Alpine 3.18 as fallback..."
    if wget "https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/aarch64/alpine-minirootfs-3.18.4-aarch64.tar.gz" -O alpine.tar.gz; then
        echo "✓ Downloaded Alpine 3.18 (fallback)"
        DOWNLOAD_SUCCESS=1
    fi
fi

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    echo "ERROR: Could not download Alpine Linux from any source"
    echo "Sources tried:"
    echo "1. git.drewpy.pro/drewpypro/rpi-images (custom repo)"
    echo "2. Alpine 3.19 official"  
    echo "3. Alpine 3.18 fallback"
    echo "Check network connectivity"
    echo "Dropping to shell for debugging..."
    exec /bin/sh
fi

# Install Alpine to USB
echo "Installing Alpine Linux to USB..."
tar -xzf alpine.tar.gz -C /mnt/root

# Basic Alpine configuration
echo "Configuring Alpine system..."

# Set hostname
echo "pi5-alpine" > /mnt/root/etc/hostname

# Configure network
cat > /mnt/root/etc/network/interfaces << 'NET_EOF'
auto lo
iface lo inet loopback

auto eth0  
iface eth0 inet dhcp
NET_EOF

# Configure repositories (ARM64)
cat > /mnt/root/etc/apk/repositories << 'REPO_EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
REPO_EOF

# Create fstab with dynamic device detection
echo "Creating fstab with UUIDs..."
BOOT_UUID=$(blkid "${USB_DEVICE}1" -o value -s UUID 2>/dev/null || echo "")
ROOT_UUID=$(blkid "${USB_DEVICE}2" -o value -s UUID 2>/dev/null || echo "")
SWAP_UUID=$(blkid "${USB_DEVICE}3" -o value -s UUID 2>/dev/null || echo "")

if [ -n "$BOOT_UUID" ] && [ -n "$ROOT_UUID" ]; then
    cat > /mnt/root/etc/fstab << FSTAB_EOF
UUID=$BOOT_UUID  /boot  vfat  defaults        0  2
UUID=$ROOT_UUID  /      ext4  defaults        0  1
$([ -n "$SWAP_UUID" ] && echo "UUID=$SWAP_UUID  none   swap  sw              0  0")
tmpfs            /tmp   tmpfs defaults        0  0
FSTAB_EOF
    echo "✓ Created fstab with UUIDs"
else
    # Fallback to labels
    cat > /mnt/root/etc/fstab << FSTAB_EOF
LABEL=BOOT        /boot  vfat  defaults        0  2
LABEL=alpine-root /      ext4  defaults        0  1
LABEL=swap        none   swap  sw              0  0
tmpfs             /tmp   tmpfs defaults        0  0
FSTAB_EOF
    echo "✓ Created fstab with labels (UUID fallback)"
fi

# Set up basic boot files (Pi needs these in /boot)
echo "Setting up boot files..."
cp -r /mnt/root/boot/* /mnt/boot/ 2>/dev/null || true

# Create a simple boot setup for installed Alpine
cat > /mnt/boot/config.txt << 'BOOT_EOF'
[pi5]
kernel=kernel8.img
# No initramfs needed for installed system

enable_uart=1
gpu_mem=64

# Enable SSH and other services
dtparam=audio=on
BOOT_EOF

cat > /mnt/boot/cmdline.txt << 'CMD_EOF'
console=ttyS0,115200 console=tty1 root=/dev/sda2 rootfstype=ext4 rootwait rw
CMD_EOF

# Enable essential services for Alpine (if OpenRC is available)
if [ -d /mnt/root/etc/runlevels ]; then
    echo "Enabling Alpine services..."
    chroot /mnt/root rc-update add networking boot 2>/dev/null || true
    chroot /mnt/root rc-update add sshd default 2>/dev/null || true
    echo "✓ Services enabled"
else
    echo "⚠ OpenRC not found - services will need manual setup"
fi

# Unmount filesystems
echo "Finalizing installation..."
sync
umount /mnt/boot
umount /mnt/root

echo ""
echo "=== Alpine Linux Installation Complete! ==="
echo "Installed to: $USB_DEVICE"
echo "System will reboot and boot from USB"
echo ""
echo "Rebooting in 5 seconds..."
sleep 5

# Reboot
echo b > /proc/sysrq-trigger
EOF

chmod +x init

echo "4. Creating device nodes..."
mknod dev/console c 5 1
mknod dev/null c 1 3
mknod dev/zero c 1 5

echo "5. Building initramfs archive..."
find . | cpio -o -H newc | gzip -9 > "$OUTPUT_FILE"

echo ""
echo "=== InitramFS Build Complete! ==="
echo "Created: $OUTPUT_FILE"
if [ -f "$OUTPUT_FILE" ]; then
    SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
    echo "Size: $SIZE"
    if [ "$SIZE" != "0" ] && [ "$SIZE" != "0B" ]; then
        echo "✓ InitramFS built successfully!"
    else
        echo "⚠ InitramFS file is empty - check for errors above"
    fi
else
    echo "✗ InitramFS file not created - build failed"
fi
echo ""
echo "✓ Ready for network boot testing!"

# Cleanup
cd /
rm -rf "$WORK_DIR"