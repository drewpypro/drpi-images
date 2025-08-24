#!/bin/bash
# boot-server.sh - Main Pi Network Boot Server
set -e

LOG_FILE="/logs/boot-server.log"
TFTPBOOT_DIR="/tftpboot"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Pi Network Boot Server Starting ==="

# Environment variables with defaults
GIT_REPO_URL=${GIT_REPO_URL:-""}
CHECK_INTERVAL=${CHECK_INTERVAL:-300}  # Check every 5 minutes
FORCE_REBUILD=${FORCE_REBUILD:-false}

cd "$TFTPBOOT_DIR"

# Function to check if boot files exist
check_boot_files() {
    local files=("bootcode.bin" "start4.elf" "fixup4.dat" "kernel8.img" "config.txt")
    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log "Missing boot file: $file"
            return 1
        fi
    done
    return 0
}

# Function to check if initramfs exists and has content
check_initramfs() {
    if [[ ! -f "initramfs8" ]]; then
        log "Missing initramfs8"
        return 1
    fi
    
    local size=$(stat -c%s "initramfs8" 2>/dev/null || echo "0")
    if [[ "$size" -lt 100000 ]]; then  # Less than 100KB is probably empty
        log "initramfs8 exists but seems empty (${size} bytes)"
        return 1
    fi
    
    log "initramfs8 exists and has content (${size} bytes)"
    return 0
}

# Function to download boot files
download_boot_files() {
    log "Downloading Pi boot files..."
    # Set OUTPUT_FILE environment for the download script
    export OUTPUT_FILE="$TFTPBOOT_DIR"
    cd "$TFTPBOOT_DIR"
    if /scripts/download-boot-files.sh 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Boot files downloaded successfully"
        return 0
    else
        log "✗ Failed to download boot files"
        return 1
    fi
}

# Function to build initramfs
build_initramfs() {
    log "Building initramfs..."
    # Set OUTPUT_FILE environment for the build script
    export OUTPUT_FILE="$TFTPBOOT_DIR/initramfs8"
    cd "$TFTPBOOT_DIR"
    if /scripts/build-initramfs.sh 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ InitramFS built successfully"
        return 0
    else
        log "✗ Failed to build initramfs"
        return 1
    fi
}

# Function to start TFTP server
start_tftp_server() {
  log "Starting TFTP server..."

  pkill -f "in.tftpd" 2>/dev/null || true

  # Ensure perms are OK for --secure
  chmod a+rx /tftpboot 2>/dev/null || true
  find /tftpboot -type f -exec chmod a+r {} \; 2>/dev/null || true

  # Run foreground (-L) so we capture the real exit code & logs
  /usr/sbin/in.tftpd -L -v \
    --user root \
    -a 0.0.0.0:69 \
    -s /tftpboot \
    --create \
    >>"$LOG_FILE" 2>&1 &

  tftp_pid=$!
  sleep 1

  if kill -0 "$tftp_pid" 2>/dev/null; then
    log "✓ TFTP server started successfully (PID: $tftp_pid)"
    return 0
  else
    log "✗ Failed to start TFTP server; recent log tail:"
    tail -n 50 "$LOG_FILE" || true
    return 1
  fi
}


# Function to check git for updates
check_git_updates() {
    if [[ -z "$GIT_REPO_URL" ]]; then
        return 1  # No git repo configured
    fi
    
    log "Checking git repository for updates: $GIT_REPO_URL"
    
    # Simple check - could be enhanced to check actual commits
    local temp_dir="/tmp/git-check-$$"
    if git clone --depth 1 "$GIT_REPO_URL" "$temp_dir" >/dev/null 2>&1; then
        rm -rf "$temp_dir"
        log "Git repository accessible"
        return 0
    else
        rm -rf "$temp_dir" 2>/dev/null || true
        log "Git repository not accessible or no updates"
        return 1
    fi
}

# Main initialization
main_init() {
    log "Performing initial setup..."
    
    # Check and download boot files if needed
    if ! check_boot_files || [[ "$FORCE_REBUILD" == "true" ]]; then
        if ! download_boot_files; then
            log "FATAL: Could not download boot files"
            exit 1
        fi
    else
        log "✓ Boot files already present"
    fi
    
    # Check and build initramfs if needed
    if ! check_initramfs || [[ "$FORCE_REBUILD" == "true" ]]; then
        if ! build_initramfs; then
            log "FATAL: Could not build initramfs"
            exit 1
        fi
    else
        log "✓ InitramFS already present and valid"
    fi
    
    # Start TFTP server
    if ! start_tftp_server; then
        log "FATAL: Could not start TFTP server"
        exit 1
    fi
    
    log "=== Pi Network Boot Server Ready ==="
    log "Files available for network boot:"
    ls -la "$TFTPBOOT_DIR" | tee -a "$LOG_FILE"
}

# Monitoring loop
monitoring_loop() {
    while true; do
        sleep "$CHECK_INTERVAL"
        
        log "Performing periodic check..."
        
        # Check if TFTP server is still running
        if ! pgrep -f "in.tftpd" >/dev/null; then
            log "TFTP server died, restarting..."
            start_tftp_server
        fi
        
        # Check for git updates if configured
        if check_git_updates; then
            log "Git updates detected, rebuilding..."
            if download_boot_files && build_initramfs; then
                log "✓ Updated from git successfully"
            else
                log "✗ Failed to update from git"
            fi
        fi
        
        # Log current status
        local initramfs_size=$(stat -c%s "initramfs8" 2>/dev/null || echo "0")
        log "Status: TFTP running, initramfs size: ${initramfs_size} bytes"
    done
}

# Signal handling
cleanup() {
    log "Shutting down Pi Network Boot Server..."
    pkill -f "in.tftpd" 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Main execution
main_init

# Start monitoring loop in background
monitoring_loop &

# Keep the main process alive
wait