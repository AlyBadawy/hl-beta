#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== K3s Cluster Provisioning ===${NC}\n"

# Prompt for server IP and export it so all sub-scripts inherit it
while true; do
  read -p "$(echo -e "${YELLOW}Enter server IP address:${NC} ")" SERVER_IP
  SERVER_IP="${SERVER_IP// /}"
  [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  echo -e "${RED}✗ Invalid IP address. Try again.${NC}"
done
export SERVER_IP
echo -e "${GREEN}✓ Server IP: $SERVER_IP${NC}\n"

run_phase() {
  local label=$1
  local script=$2

  echo -e "${YELLOW}========================================${NC}"
  echo -e "${YELLOW}${label}${NC}"
  echo -e "${YELLOW}========================================${NC}\n"

  if [ ! -f "$SCRIPT_DIR/scripts/$script" ]; then
    echo -e "${RED}Error: $script not found${NC}"
    exit 1
  fi

  chmod +x "$SCRIPT_DIR/scripts/$script"
  "$SCRIPT_DIR/scripts/$script"
}

run_phase "Phase 2: SSH Connectivity Check"          check-ssh-connection
run_phase "Phase 3: System Updates & Dependencies"   update-dependencies
run_phase "Phase 4: NAS Storage Mounting"            mount-nas
run_phase "Phase 5: K3s Cluster Installation"        install-k3s
run_phase "Phase 6: Cluster Configuration"           configure-cluster

echo -e "\n${GREEN}=== ✓ Provisioning Complete ===${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "  - Review logs:      cat provision.log"
echo "  - Verify cluster:   kubectl get nodes"
echo "  - Verify config:    kubectl get configmap cluster-config -n cluster-config"
echo "  - Bootstrap GitOps: ./provision/provision-gitops.sh"
