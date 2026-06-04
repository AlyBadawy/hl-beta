#!/bin/bash

# Hardcoded homelab defaults. Override any value by exporting it before running.

SSH_USER="${SSH_USER:-homelab}"

NAS_IP="${NAS_IP:-172.20.20.2}"
NAS_BASE_SHARE="${NAS_BASE_SHARE:-/var/nfs/shared}"
NAS_BASE_MOUNT="${NAS_BASE_MOUNT:-/mnt/nas}"

SMTP_SERVER="${SMTP_SERVER:-smtp.resend.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_FROM="${SMTP_FROM:-homelab@alybadawy.com}"

ADMIN_EMAIL="${ADMIN_EMAIL:-homelab@alybadawy.com}"

DOMAIN="${DOMAIN:-in.alybadawy.com}"

GIT_REPO="${GIT_REPO:-https://github.com/AlyBadawy/hl-beta}"

# Prompt for SERVER_IP if not already set (e.g. when running a sub-script directly).
require_server_ip() {
  if [ -n "$SERVER_IP" ]; then return; fi

  local RED='\033[0;31m'
  local YELLOW='\033[1;33m'
  local NC='\033[0m'

  while true; do
    read -p "$(echo -e "${YELLOW}Enter server IP address:${NC} ")" SERVER_IP
    SERVER_IP="${SERVER_IP// /}"
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echo -e "${RED}✗ Invalid IP address. Try again.${NC}"
  done
  export SERVER_IP
}
