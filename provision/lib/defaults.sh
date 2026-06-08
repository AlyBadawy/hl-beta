#!/bin/bash

# Hardcoded homelab defaults. Override any value by exporting it before running.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SSH_USER="${SSH_USER:-homelab}"
SSH_TIMEOUT="${SSH_TIMEOUT:-5}"

NAS_IP="${NAS_IP:-172.20.20.2}"
NAS_BASE_SHARE="${NAS_BASE_SHARE:-/var/nfs/shared}"
NAS_BASE_MOUNT="${NAS_BASE_MOUNT:-/mnt/nas}"

ADMIN_EMAIL="${ADMIN_EMAIL:-homelab@alybadawy.com}"

DOMAIN="${DOMAIN:-in.alybadawy.com}"

GIT_REPO="${GIT_REPO:-https://github.com/AlyBadawy/hl-beta}"

# Prompt for SERVER_IP if not already set (e.g. when running a sub-script directly).
require_server_ip() {
  if [ -n "$SERVER_IP" ]; then return; fi
  while true; do
    read -p "$(echo -e "${YELLOW}Enter server IP address:${NC} ")" SERVER_IP
    SERVER_IP="${SERVER_IP// /}"
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echo -e "${RED}✗ Invalid IP address. Try again.${NC}"
  done
  export SERVER_IP
}

# Log to stdout and append to $LOG_FILE (set by the calling script).
log_output() { echo -e "$1" | tee -a "$LOG_FILE"; }

# Run a command over SSH. Args: command, description, [fail_on_error=true].
run_remote_command() {
  local command=$1
  local description=$2
  local fail_on_error=${3:-true}

  log_output "${YELLOW}$description${NC}"

  if output=$(ssh \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=QUIET \
    "$SSH_USER@$SERVER_IP" \
    "$command" 2>&1); then
    log_output "${GREEN}✓ Success${NC}"
    return 0
  else
    log_output "${RED}✗ Failed: $output${NC}"
    [ "$fail_on_error" = "true" ] && return 1 || return 0
  fi
}
