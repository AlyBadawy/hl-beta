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

# Check if config-secrets script exists
if [ ! -f "$SCRIPT_DIR/scripts/config-secrets" ]; then
  echo -e "${RED}Error: config-secrets script not found at $SCRIPT_DIR/scripts/config-secrets${NC}"
  exit 1
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/scripts/config-secrets"

# Run config-secrets
echo -e "${YELLOW}Step 1: Configure Secrets${NC}"
"$SCRIPT_DIR/scripts/config-secrets"

echo -e "\n${GREEN}✓ Provisioning setup complete${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review the configuration in config/secrets.yaml"
echo "  2. Run: ./provision/provision.sh deploy (when ready)"
