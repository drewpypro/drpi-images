#!/bin/sh
# scripts/build-initramfs.sh
# Builds minimal initramfs for Pi5 network boot that can handle basic boot and installation

set -e

echo "=== Building InitramFS for Pi5 Network Boot ==="

# Install required tools
apk add --no-cache wget cpio gzip findutils rsync

WORK_DIR="/tmp/initramfs-build"
OUTPUT_FILE="${OUTPUT_FILE:-/tftpboot/initramfs.cpio.gz}"

# Clean and create working directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "1. Creating initramfs directory structure..."
mkdir -p {bin,sbin,etc,proc,sys,dev,tmp,mnt,newroot,var,root}
mkdir -p {usr/bin,usr/sbin,lib,lib64}
mkdir -p {mnt/boot,mnt/root,mnt/usb}

echo "2. Installing busybox for ARM64..."
# Get busybox-static which should work for ARM64
apk add --no-cache busybox-static

# Find busybox location
BUSYBOX_PATH=$(which busybox || find /bin /sbin /usr/bin /usr/sbin -name "busybox*" -type f | head -1)

if [ -z "$BUSYBOX_PATH" ] || [ ! -f "$BUSYBOX_PATH" ]; then
    echo "ERROR: Could not find busybox binary"
    exit 1
fi

echo "Found busybox at: $BUSYBOX_PATH"
cp "$BUSYBOX_PATH" "$WORK_DIR/bin/busybox"
chmod +x "$WORK_DIR/bin/busybox"

# Verify busybox works
cd "$WORK_DIR"
if ! ./bin/busybox --help >/dev/null 2>&1; then
    echo "ERROR: Busybox not working"
    file ./bin/busybox
    ldd ./bin/busybox 2>/dev/null || echo "Static binary (good)"
    exit 1
fi

echo "✓ Busybox installed and verified"

# Create essential symlinks in bin/
cd bin
for cmd in sh ash bash cat cp mv rm ls ln mkdir mount umount \
           wget curl tar gzip gunzip ip ping udhcpc grep awk sed \
           cut sort head tail find xargs sleep echo printf test \
           tr dd blkid lsblk fdisk mkfs.ext4 mkfs.fat switch_root \
           reboot poweroff mknod chmod chown sync; do
    ln -sf busybox "$cmd" 2>/dev/null || true
done
cd ..

# Create essential symlinks in sbin/
cd sbin
for cmd in mount umount blkid mkfs.ext4 mkfs.fat fdisk switch_root \
           ip route ifconfig init; do
    ln -sf ../bin/busybox "$cmd" 2>/dev/null || true
done
cd ..

echo "3. Creating essential device nodes..."
mknod dev/console c 5 1
mknod dev/null c 1 3
mknod dev/zero c 1 5
mknod dev/random c 1 8
mknod dev/urandom c 1 9

# Create some basic /dev entries that might be needed
mkdir -p dev/pts
mknod dev/tty c 5 0
for i in $(seq 0 7); do
    mknod "dev/tty$i" c 4 "$i"
done

echo "4. Creating init script..."
cat > init << 'INIT_EOF'
#!/bin/sh
# Pi5 Network Boot InitramFS

echo "=== Pi5 Network Boot InitramFS Starting ==="

# Set PATH
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"

# Mount essential filesystems first
echo "Mounting essential filesystems..."
mount -t proc proc /proc || echo "Failed to mount /proc"
mount -t sysfs sysfs /sys || echo "Failed to mount /sys"
mount -t devtmpfs devtmpfs /dev 2>/dev/null || echo "devtmpfs not available"

# Create additional device nodes if devtmpfs didn't
[ ! -c /dev/console ] && mknod /dev/console c 5 1
[ ! -c /dev/null ] && mknod /dev/null c 1 3

echo "Basic filesystem setup complete"

# Network setup
echo "Setting up network..."
ip link set lo up 2>/dev/null || true

# Try to bring up eth0
if ip link show eth0 >/dev/null 2>&1; then
    echo "Found eth0, bringing up..."
    ip link set eth0 up
    
    # Try DHCP
    echo "Attempting DHCP on eth0..."
    if command -v udhcpc >/dev/null; then
        udhcpc -i eth0 -n -q -t 5 2>/dev/null || echo "DHCP failed, continuing..."
    fi
    
    # Show network status
    IP=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -n "$IP" ] && echo "Network configured: $IP" || echo "No IP assigned"
else
    echo "No eth0 interface found"
fi

echo "Network setup complete"

# Look for USB installation target or provide interactive shell
echo "Checking for installation targets..."

USB_DEVICE=""
for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
    if [ -b "$dev" ]; then
        echo "Found storage device: $dev"
        # Check if it looks like our target USB
        if blkid "${dev}2" 2>/dev/null | grep -q "alpine-root"; then
            USB_DEVICE="$dev"
            echo "Found prepared Alpine USB drive: $USB_DEVICE"
            break
        fi
    fi
done

if [ -n "$USB_DEVICE" ]; then
    echo "Starting Alpine installation to $USB_DEVICE..."
    
    # Mount target partitions
    mkdir -p /mnt/boot /mnt/root
    if mount "${USB_DEVICE}1" /mnt/boot 2>/dev/null && mount "${USB_DEVICE}2" /mnt/root 2>/dev/null; then
        echo "USB partitions mounted"
        
        # Download and install Alpine
        cd /tmp
        echo "Downloading Alpine Linux..."
        
        # Try multiple sources
        DOWNLOADED=0
        for URL in \
            "https://git.drewpy.pro/drewpypro/rpi-images/raw/main/alpine/alpine-rpi-latest.tar.gz" \
            "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.1-aarch64.tar.gz" \
            "https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/aarch64/alpine-minirootfs-3.18.5-aarch64.tar.gz"; do
            
            echo "Trying: $URL"
            if wget -q -T 30 "$URL" -O alpine.tar.gz; then
                echo "✓ Downloaded Alpine"
                DOWNLOADED=1
                break
            fi
        done
        
        if [ $DOWNLOADED -eq 1 ]; then
            echo "Installing Alpine to USB..."
            tar -xzf alpine.tar.gz -C /mnt/root 2>/dev/null || echo "Extract failed"
            
            # Basic configuration
            echo "pi5-alpine" > /mnt/root/etc/hostname 2>/dev/null || true
            
            # Network config
            cat > /mnt/root/etc/network/interfaces 2>/dev/null << 'NET_EOF' || true
auto lo
iface lo inet loopback
auto eth0  
iface eth0 inet dhcp
NET_EOF
            
            # Repositories
            cat > /mnt/root/etc/apk/repositories 2>/dev/null << 'REPO_EOF' || true
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
REPO_EOF
            
            # Fstab with UUIDs if possible
            BOOT_UUID=$(blkid "${USB_DEVICE}1" -o value -s UUID 2>/dev/null)
            ROOT_UUID=$(blkid "${USB_DEVICE}2" -o value -s UUID 2>/dev/null)
            
            if [ -n "$BOOT_UUID" ] && [ -n "$ROOT_UUID" ]; then
                cat > /mnt/root/etc/fstab << FSTAB_EOF
UUID=$BOOT_UUID  /boot  vfat  defaults  0  2
UUID=$ROOT_UUID  /      ext4  defaults  0  1
tmpfs            /tmp   tmpfs defaults  0  0
FSTAB_EOF
            else
                cat > /mnt/root/etc/fstab << FSTAB_EOF
/dev/sda1  /boot  vfat  defaults  0  2
/dev/sda2  /      ext4  defaults  0  1
tmpfs      /tmp   tmpfs defaults  0  0
FSTAB_EOF
            fi
            
            sync
            umount /mnt/boot /mnt/root 2>/dev/null || true
            
            echo "✓ Alpine installation complete!"
            echo "System will reboot to boot from USB..."
            sleep 3
            reboot
        else
            echo "Failed to download Alpine"
        fi
    else
        echo "Failed to mount USB partitions"
    fi
fi

echo ""
echo "=== No installation target found or installation failed ==="
echo "Available block devices:"
lsblk 2>/dev/null || ls -la /dev/sd* /dev/nvme* 2>/dev/null || echo "No storage devices found"
echo ""
echo "Network interfaces:"
ip link show 2>/dev/null || echo "No network interfaces"
echo ""
echo "Dropping to interactive shell for debugging..."
echo "Type 'reboot' to restart or investigate the system manually"
echo ""

# Drop to shell
exec /bin/sh
INIT_EOF

chmod +x init

echo "5. Creating basic etc files..."
# Create minimal etc structure
cat > etc/passwd << 'PASSWD_EOF'
root:x:0:0:root:/root:/bin/sh
PASSWD_EOF

cat > etc/group << 'GROUP_EOF'
root:x:0:
PASSWD_EOF

# Create basic profile
cat > etc/profile << 'PROFILE_EOF'
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export PS1="Pi5-InitramFS # "
PROFILE_EOF

echo "6. Building initramfs archive..."
# Create the cpio archive
find . -print0 | cpio --null --create --verbose --format=newc | gzip -9 > "$OUTPUT_FILE"

# Verify the output
if [ -f "$OUTPUT_FILE" ]; then
    SIZE=$(stat -c %s "$OUTPUT_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 100000 ]; then
        echo "✓ InitramFS created successfully: $OUTPUT_FILE ($SIZE bytes)"
        
        # Test the archive
        echo "Testing archive integrity..."
        if gzip -t "$OUTPUT_FILE" 2>/dev/null; then
            echo "✓ Archive integrity check passed"
        else
            echo "⚠ Archive may be corrupted"
        fi
    else
        echo "⚠ InitramFS seems too small: $SIZE bytes"
        exit 1
    fi
else
    echo "✗ Failed to create InitramFS"
    exit 1
fi

echo "7. Creating compatible cmdline.txt..."
cat > "${OUTPUT_FILE%/*}/cmdline.txt" << 'CMDLINE_EOF'
console=serial0,115200 console=tty1 ip=dhcp root=/dev/ram0 rw init=/init
CMDLINE_EOF

echo ""
echo "=== InitramFS Build Complete ==="
echo "Output: $OUTPUT_FILE"
echo "Size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
echo ""
echo "Ready for Pi5 network boot!"

# Cleanup
cd /
rm -rf "$WORK_DIR"