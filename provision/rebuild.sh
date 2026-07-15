#!/usr/bin/env bash
#
# Rebuild orchestrator — provisions the server (Steps 1–5), seeds the two
# manually-managed secrets (Vault unseal key, Cloudflare API token), and
# bootstraps ArgoCD (Step 7).
#
# Intentionally stops before activate-gitops.sh so you can do a final sanity
# check (secrets present, ArgoCD healthy) before handing cluster control to
# ArgoCD.
#
# Next step (manual): ./provision/activate-gitops.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/defaults.sh"

header() {
  echo -e "\n${YELLOW}========================================${NC}"
  echo -e "${YELLOW}${1}${NC}"
  echo -e "${YELLOW}========================================${NC}\n"
}

log()  { echo -e "${BLUE}==>${NC} ${*}"; }
ok()   { echo -e "${GREEN}✓${NC} ${*}"; }
fail() { echo -e "${RED}✗ ${*}${NC}" >&2; exit 1; }

# ── Banner ───────────────────────────────────────────────────────────────────

echo -e "${GREEN}=== K3s Cluster Rebuild ===${NC}\n"
echo "Provisions the server, seeds secrets, and bootstraps ArgoCD. All"
echo "interactive prompts are collected upfront — no further interruptions"
echo "until the rebuild completes."
echo ""

# ── Collect all inputs upfront ───────────────────────────────────────────────

# Server IP
while true; do
  read -rp "$(echo -e "${YELLOW}Enter server IP address:${NC} ")" SERVER_IP
  SERVER_IP="${SERVER_IP// /}"
  [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  echo -e "${RED}✗ Invalid IP address. Try again.${NC}"
done
export SERVER_IP
ok "Server IP: $SERVER_IP"

echo ""

# Vault unseal key (silent — does not echo to terminal)
read -rsp "$(echo -e "${YELLOW}Vault unseal key (from offline backup):${NC} ")" VAULT_UNSEAL_KEY; echo
[[ -n "$VAULT_UNSEAL_KEY" ]] || fail "Vault unseal key is required."
ok "Vault unseal key: captured"

echo ""

# Cloudflare API token (silent — bootstrap-argocd reads this env var and skips its prompt)
read -rsp "$(echo -e "${YELLOW}Cloudflare API token (Zone:DNS:Edit for alybadawy.com):${NC} ")" CLOUDFLARE_API_TOKEN; echo
[[ -n "$CLOUDFLARE_API_TOKEN" ]] || fail "Cloudflare API token is required."
export CLOUDFLARE_API_TOKEN
ok "Cloudflare API token: captured"

echo ""

# ── Steps 1–8 ────────────────────────────────────────────────────────────────

run_step() {
  local label=$1
  local script=$2

  header "$label"

  if [ ! -f "$SCRIPT_DIR/scripts/$script" ]; then
    fail "Script not found: provision/scripts/$script"
  fi

  chmod +x "$SCRIPT_DIR/scripts/$script"
  "$SCRIPT_DIR/scripts/$script"
}

run_step "Step 1: SSH Connectivity Check"        check-ssh-connection
run_step "Step 2: System Updates & Dependencies" update-dependencies
run_step "Step 3: NAS Storage Mounting"          mount-nas
run_step "Step 4: K3s Cluster Installation"      install-k3s
run_step "Step 5: Cluster Configuration"         configure-cluster

echo ""
ok "Server provisioning complete (Steps 1–5)."

# ── Step 6: Seed the Vault unseal key ────────────────────────────────────────

header "Step 6: Seed Vault Unseal Key"

log "Creating 'security' namespace"
kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -

log "Creating vault-unseal-key secret"
kubectl create secret generic vault-unseal-key \
  --namespace=security \
  --from-literal=key="$VAULT_UNSEAL_KEY" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

ok "vault-unseal-key seeded in namespace 'security'."

# ── Step 7: ArgoCD ───────────────────────────────────────────────────────────
# CLOUDFLARE_API_TOKEN is already exported — bootstrap-argocd detects it
# and skips its interactive prompt, then seeds cloudflare-api-token in 'networking'.

run_step "Step 7: Bootstrap ArgoCD" bootstrap-argocd

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}=== ✓ Rebuild Preparation Complete ===${NC}"
echo ""
echo "Verify everything is in place before activating GitOps:"
echo ""
echo "  kubectl get nodes"
echo "  kubectl get secret vault-unseal-key -n security"
echo "  kubectl get secret cloudflare-api-token -n networking"
echo "  kubectl get pods -n argocd"
echo ""
echo "When satisfied, hand cluster ownership to ArgoCD:"
echo ""
echo -e "  ${YELLOW}./provision/activate-gitops.sh${NC}"
echo ""
