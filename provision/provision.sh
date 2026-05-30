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
echo -e "${YELLOW}Phase 1: Configuration Collection${NC}"
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
echo -e "${YELLOW}Phase 2: SSH Connectivity Check${NC}"
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
echo -e "${YELLOW}Phase 3: System Updates & Dependencies${NC}"
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
echo -e "${YELLOW}Phase 4: NAS Storage Mounting${NC}"
echo -e "${YELLOW}========================================${NC}\n"

# Check if mount-nas script exists
if [ ! -f "$SCRIPT_DIR/scripts/mount-nas" ]; then
  echo -e "${RED}Error: mount-nas script not found${NC}"
  exit 1
fi

# Make script executable and run it
chmod +x "$SCRIPT_DIR/scripts/mount-nas"
"$SCRIPT_DIR/scripts/mount-nas"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Phase 5: K3s Cluster Installation${NC}"
echo -e "${YELLOW}========================================${NC}\n"

# Check if install-k3s script exists
if [ ! -f "$SCRIPT_DIR/scripts/install-k3s" ]; then
  echo -e "${RED}Error: install-k3s script not found${NC}"
  exit 1
fi

# Make script executable and run it
chmod +x "$SCRIPT_DIR/scripts/install-k3s"
"$SCRIPT_DIR/scripts/install-k3s"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Phase 6: Cluster Configuration Provisioning${NC}"
echo -e "${YELLOW}========================================${NC}\n"

# Check if configure-cluster script exists
if [ ! -f "$SCRIPT_DIR/scripts/configure-cluster" ]; then
  echo -e "${RED}Error: configure-cluster script not found${NC}"
  exit 1
fi

# Make script executable and run it
chmod +x "$SCRIPT_DIR/scripts/configure-cluster"
"$SCRIPT_DIR/scripts/configure-cluster"

echo -e "\n${GREEN}=== ✓ Provisioning Complete ===${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "  - Review logs: cat provision.log"
echo "  - Test cluster: kubectl get nodes"
echo "  - Verify cluster config: kubectl get configmap cluster-config -n cluster-config -o yaml"
echo "  - Verify cluster secrets: kubectl get secret cluster-config -n cluster-config -o yaml"