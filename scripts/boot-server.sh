#!/bin/bash
set -euo pipefail

LOG_FILE="/logs/boot-server.log"
TFTPBOOT_DIR="/tftpboot"

log(){ echo "[$(date +'%F %T')] $1" | tee -a "$LOG_FILE"; }

log "=== Pi Network Boot Server Starting ==="

GIT_REPO_URL=${GIT_REPO_URL:-""}
CHECK_INTERVAL=${CHECK_INTERVAL:-300}
FORCE_REBUILD=${FORCE_REBUILD:-false}

cd "$TFTPBOOT_DIR"

check_boot_files() {
  # Pi 5 essentials — do NOT require start4.elf/fixup*
  local files=("kernel8.img" "bcm2712-rpi-5-b.dtb" "config.txt" "cmdline.txt")
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { log "Missing boot file: $f"; return 1; }
  done
  return 0
}

check_initramfs() {
  local f="initramfs.cpio.gz"     # <— standardize on this name
  if [[ ! -f "$f" ]]; then log "Missing $f"; return 1; fi
  local size; size=$(stat -c%s "$f" || echo 0)
  if [[ "$size" -lt 102400 ]]; then
    log "$f exists but seems too small ($size bytes)"
    return 1
  fi
  log "$f present ($size bytes)"
  return 0
}

download_boot_files() {
  log "Downloading boot files into $TFTPBOOT_DIR ..."
  OUTPUT_DIR="$TFTPBOOT_DIR" /scripts/download-boot-files.sh 2>&1 | tee -a "$LOG_FILE"
}

build_initramfs() {
  log "Building initramfs..."
  # Set OUTPUT_FILE so build script knows where to write
  OUTPUT_FILE="$TFTPBOOT_DIR/initramfs.cpio.gz" /scripts/build-initramfs.sh 2>>"$LOG_FILE"
  log "Initramfs built at $TFTPBOOT_DIR/initramfs.cpio.gz"
}

start_tftp_server() {
  log "Starting TFTP server..."
  pkill -f "in.tftpd" 2>/dev/null || true

  chmod a+rx "$TFTPBOOT_DIR"
  find "$TFTPBOOT_DIR" -type f -exec chmod a+r {} \;

  /usr/sbin/in.tftpd -L -v \
    --user root \
    -a 0.0.0.0:69 \
    -s "$TFTPBOOT_DIR" \
    --secure \
    >>"$LOG_FILE" 2>&1 &

  tftp_pid=$!
  sleep 1
  if kill -0 "$tftp_pid" 2>/dev/null; then
    log "✓ TFTP server started (PID $tftp_pid)"
  else
    log "✗ TFTP failed to start"; tail -n 50 "$LOG_FILE" || true; exit 1
  fi
}

check_git_updates() {
  [[ -z "$GIT_REPO_URL" ]] && return 1
  log "Checking git repo: $GIT_REPO_URL"
  local tmp="/tmp/git-check-$$"
  if git clone --depth 1 "$GIT_REPO_URL" "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"; log "Git repo accessible"; return 0
  fi
  rm -rf "$tmp" 2>/dev/null || true
  log "Git not accessible (or no updates)"; return 1
}

main_init() {
  log "Initial setup…"
  if ! check_boot_files || [[ "$FORCE_REBUILD" == "true" ]]; then
    download_boot_files
  else
    log "✓ Boot files already present"
  fi

  if ! check_initramfs || [[ "$FORCE_REBUILD" == "true" ]]; then
    build_initramfs
  else
    log "✓ Initramfs present"
  fi

  start_tftp_server
  log "=== Ready ==="
  ls -la "$TFTPBOOT_DIR" | tee -a "$LOG_FILE"
}

monitoring_loop() {
  while true; do
    sleep "$CHECK_INTERVAL"
    if ! pgrep -f "in.tftpd" >/dev/null; then
      log "TFTP died; restarting…"; start_tftp_server
    fi
    if check_git_updates; then
      log "Refreshing boot files + initramfs from git trigger"
      download_boot_files || log "Download failed"
      build_initramfs || log "Initramfs build failed"
    fi
    local sz=$(stat -c%s "$TFTPBOOT_DIR/initramfs.cpio.gz" 2>/dev/null || echo 0)
    log "Status: TFTP up, initramfs size ${sz} bytes"
  done
}

trap 'log "Shutting down"; pkill -f "in.tftpd" 2>/dev/null || true; exit 0' SIGTERM SIGINT

main_init
monitoring_loop &
wait
