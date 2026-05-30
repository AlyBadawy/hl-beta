#!/bin/bash

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== K3s Cluster Provisioning ===${NC}\n"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Step 1: Configure Secrets${NC}"
echo -e "${YELLOW}========================================${NC}"

# Check if config-secrets script exists
if [ ! -f "$SCRIPT_DIR/scripts/config-secrets" ]; then
  echo -e "${RED}Error: config-secrets script not found at $SCRIPT_DIR/scripts/config-secrets${NC}"
  exit 1
fi

# Check if secrets already exist
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/config"
SECRETS_FILE="$CONFIG_DIR/secrets.yaml"

if [ -f "$SECRETS_FILE" ]; then
  echo -e "${GREEN}✓ Existing configuration found at $SECRETS_FILE${NC}\n"
  read -p "$(echo -e ${YELLOW}Reconfigure secrets?${NC}) [y/N]: " reconfigure

  if [[ ! $reconfigure =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Skipping secret configuration, using existing secrets${NC}\n"
    SKIP_SECRETS=true
  fi
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/scripts/config-secrets"

# Run config-secrets only if not skipping
if [ "$SKIP_SECRETS" != "true" ]; then
  "$(mkdir -p "$CONFIG_DIR")"
  "$SCRIPT_DIR/scripts/config-secrets"
  echo -e "\n${GREEN}✓ Secret configuration complete${NC}"
else
  echo -e "${GREEN}✓ Using existing secrets${NC}"
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Step 2: Check SSH Connection${NC}"
echo -e "${YELLOW}========================================${NC}\n"

# Check if check-ssh-connection script exists
if [ ! -f "$SCRIPT_DIR/scripts/check-ssh-connection" ]; then
  echo -e "${RED}Error: check-ssh-connection script not found${NC}"
  exit 1
fi

# Make script executable and run it
chmod +x "$SCRIPT_DIR/scripts/check-ssh-connection"
"$SCRIPT_DIR/scripts/check-ssh-connection"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Step 3: Update System & Install Dependencies${NC}"
echo -e "${YELLOW}========================================${NC}\n"

# Check if update-dependencies script exists
if [ ! -f "$SCRIPT_DIR/scripts/update-dependencies" ]; then
  echo -e "${RED}Error: update-dependencies script not found${NC}"
  exit 1
fi

# Make script executable and run it
chmod +x "$SCRIPT_DIR/scripts/update-dependencies"
"$SCRIPT_DIR/scripts/update-dependencies"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Step 4: Mount NAS Storage${NC}"
echo -e "${YELLOW}========================================${NC}\n"

# Check if mount-nas script exists
if [ ! -f "$SCRIPT_DIR/scripts/mount-nas" ]; then
  echo -e "${RED}Error: mount-nas script not found${NC}"
  exit 1
fi

# Make script executable and run it
chmod +x "$SCRIPT_DIR/scripts/mount-nas"
"$SCRIPT_DIR/scripts/mount-nas"

echo -e "\n${GREEN}=== ✓ Provisioning Complete ===${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "  - Review logs: cat provision.log"
echo "  - Server is ready for k3s installation"