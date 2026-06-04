#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config/secrets.yaml"
LOG_FILE="$PROJECT_DIR/provision.log"
K8S_DIR="$PROJECT_DIR/k8s"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SSH_TIMEOUT=5
SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=QUIET"

NGINX_CHART_VERSION="4.11.0"
ARGOCD_CHART_VERSION="7.6.0"

source "$SCRIPT_DIR/lib/config.sh"

log_output() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

echo -e "${GREEN}=== GitOps Bootstrap ===${NC}\n"

# ─────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}✗ config/secrets.yaml not found. Run provision-server.sh first.${NC}"
  exit 1
fi

log_output "${YELLOW}Loading SSH configuration...${NC}"
if ! load_ssh_config "$CONFIG_FILE"; then
  log_output "${RED}✗ Failed to load SSH configuration${NC}"
  exit 1
fi
log_output "${GREEN}✓ SSH config loaded (${SSH_USER}@${SERVER_IP})${NC}\n"

# ─────────────────────────────────────────────────────────────────
# Git URL prompt
# ─────────────────────────────────────────────────────────────────
while true; do
  read -p "$(echo -e "${YELLOW}Enter git repo URL (https:// or git@):${NC} ")" GIT_URL
  GIT_URL="${GIT_URL// /}"
  if [[ "$GIT_URL" =~ ^(https://|git@) ]]; then
    break
  fi
  echo -e "${RED}✗ Invalid URL. Must start with https:// or git@${NC}"
done
log_output "${GREEN}✓ Git repo: $GIT_URL${NC}\n"

# ─────────────────────────────────────────────────────────────────
# Vercel API Token prompt (for cert-manager DNS-01 challenge)
# ─────────────────────────────────────────────────────────────────
while true; do
  read -s -p "$(echo -e "${YELLOW}Enter Vercel API Token (for DNS-01 wildcard cert):${NC} ")" VERCEL_API_TOKEN
  echo
  VERCEL_API_TOKEN="${VERCEL_API_TOKEN// /}"
  if [ -n "$VERCEL_API_TOKEN" ]; then
    break
  fi
  echo -e "${RED}✗ Vercel API token cannot be empty${NC}"
done
log_output "${GREEN}✓ Vercel API token captured${NC}\n"

# ─────────────────────────────────────────────────────────────────
# Step 1: Install nginx-ingress via Helm
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 1: Installing nginx-ingress Controller${NC}\n"

NGINX_RUNNING=$(kubectl get daemonset -n ingress-nginx \
  -l 'app.kubernetes.io/name=ingress-nginx' \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$NGINX_RUNNING" -gt 0 ]; then
  log_output "${GREEN}✓ nginx-ingress already running — skipping install${NC}\n"
else
  log_output "  Adding nginx-ingress Helm repository..."
  if ssh $SSH_OPTS "$SSH_USER@$SERVER_IP" \
    "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update" >> "$LOG_FILE" 2>&1; then
    log_output "${GREEN}✓ Repository ready${NC}"
  else
    log_output "${YELLOW}⚠ Repository may already exist (continuing)${NC}"
  fi

  log_output "  Creating ingress-nginx namespace..."
  kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1

  NGINX_VALUES=$(cat <<'EOF'
controller:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  kind: DaemonSet
  service:
    type: ClusterIP
  ingressClassResource:
    default: true
EOF
)

  log_output "  Installing nginx-ingress via Helm (version $NGINX_CHART_VERSION)..."
  if ssh $SSH_OPTS "$SSH_USER@$SERVER_IP" \
    "export KUBECONFIG=~/.kube/config && helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --version $NGINX_CHART_VERSION \
      --values - \
      --wait \
      --timeout 5m" <<< "$NGINX_VALUES" >> "$LOG_FILE" 2>&1; then
    log_output "${GREEN}✓ nginx-ingress installed${NC}"
  else
    log_output "${RED}✗ Failed to install nginx-ingress${NC}"
    log_output "${RED}  Check logs: tail -50 $LOG_FILE${NC}"
    exit 1
  fi

  log_output "  Handing off nginx-ingress to ArgoCD (removing Helm tracking secret)..."
  kubectl delete secret \
    --namespace ingress-nginx \
    --selector "owner=helm,name=nginx-ingress" \
    --ignore-not-found >> "$LOG_FILE" 2>&1
  log_output "${GREEN}✓ nginx-ingress ready for ArgoCD management${NC}\n"
fi

# ─────────────────────────────────────────────────────────────────
# Step 2: Create ArgoCD namespace
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 2: Creating ArgoCD Namespace${NC}\n"

if kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1; then
  log_output "${GREEN}✓ ArgoCD namespace ready${NC}\n"
else
  log_output "${RED}✗ Failed to create ArgoCD namespace${NC}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
# Step 3: Install ArgoCD via Helm
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 3: Installing ArgoCD${NC}\n"

ARGOCD_RUNNING=$(kubectl get deployment -n argocd argocd-server --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$ARGOCD_RUNNING" -gt 0 ]; then
  log_output "${GREEN}✓ ArgoCD already running — skipping install${NC}\n"
else
  log_output "  Adding ArgoCD Helm repository..."
  if ssh $SSH_OPTS "$SSH_USER@$SERVER_IP" \
    "helm repo add argo https://argoproj.github.io/argo-helm && helm repo update" >> "$LOG_FILE" 2>&1; then
    log_output "${GREEN}✓ Repository ready${NC}"
  else
    log_output "${YELLOW}⚠ Repository may already exist (continuing)${NC}"
  fi

  ARGOCD_BOOTSTRAP_VALUES=$(cat <<'EOF'
server:
  insecure: true
  replicas: 1
controller:
  replicas: 1
repoServer:
  replicas: 1
redis:
  enabled: true
configs:
  cm:
    server.insecure: "true"
EOF
)

  log_output "  Installing ArgoCD via Helm (version $ARGOCD_CHART_VERSION)..."
  if ssh $SSH_OPTS "$SSH_USER@$SERVER_IP" \
    "export KUBECONFIG=~/.kube/config && helm upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      --version $ARGOCD_CHART_VERSION \
      --values - \
      --wait \
      --timeout 5m" <<< "$ARGOCD_BOOTSTRAP_VALUES" >> "$LOG_FILE" 2>&1; then
    log_output "${GREEN}✓ ArgoCD installed${NC}"
  else
    log_output "${RED}✗ Failed to install ArgoCD${NC}"
    log_output "${RED}  Check logs: tail -50 $LOG_FILE${NC}"
    exit 1
  fi

  log_output "  Handing off ArgoCD to self-management (removing Helm tracking secret)..."
  kubectl delete secret \
    --namespace argocd \
    --selector "owner=helm,name=argocd" \
    --ignore-not-found >> "$LOG_FILE" 2>&1
  log_output "${GREEN}✓ ArgoCD ready for self-management${NC}\n"
fi

# ─────────────────────────────────────────────────────────────────
# Step 4: Create cert-manager namespace and Vercel API token secret
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 4: Creating cert-manager Namespace and Vercel Secret${NC}\n"

log_output "  Creating cert-manager namespace..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
log_output "${GREEN}✓ cert-manager namespace ready${NC}"

log_output "  Creating vercel-api-token secret..."
if kubectl create secret generic vercel-api-token \
  --namespace cert-manager \
  --from-literal=token="$VERCEL_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1; then
  log_output "${GREEN}✓ vercel-api-token secret ready in cert-manager namespace${NC}\n"
else
  log_output "${RED}✗ Failed to create vercel-api-token secret${NC}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
# Step 5: Create root-app Application (Kustomize App-of-Apps)
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 5: Creating Root App (App-of-Apps)${NC}\n"

ROOT_APP_MANIFEST=$(cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $GIT_URL
    targetRevision: main
    path: k8s/root-app
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
)

log_output "  Applying root-app Application..."
echo "$ROOT_APP_MANIFEST" | kubectl apply -f - >> "$LOG_FILE" 2>&1
log_output "${GREEN}✓ root-app Application created${NC}\n"

# ─────────────────────────────────────────────────────────────────
# Step 6: Wait for ArgoCD to be ready
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 6: Waiting for ArgoCD to be Ready${NC}\n"

log_output "  Waiting for argocd-server deployment (up to 5 minutes)..."
if kubectl rollout status deployment/argocd-server -n argocd --timeout=5m >> "$LOG_FILE" 2>&1; then
  log_output "${GREEN}✓ ArgoCD server is running${NC}\n"
else
  log_output "${YELLOW}⚠ ArgoCD server did not roll out in time (continuing)${NC}\n"
fi

# ─────────────────────────────────────────────────────────────────
# Step 7: Retrieve admin credentials
# ─────────────────────────────────────────────────────────────────
log_output "${YELLOW}Step 7: Retrieving ArgoCD Admin Credentials${NC}\n"

ADMIN_PASSWORD=""
for i in {1..30}; do
  ADMIN_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [ -n "$ADMIN_PASSWORD" ]; then
    log_output "${GREEN}✓ Admin credentials retrieved${NC}\n"
    break
  fi
  if [ $i -eq 30 ]; then
    ADMIN_PASSWORD="(not yet available — run: kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
    log_output "${YELLOW}⚠ Could not retrieve admin password yet${NC}\n"
    break
  fi
  log_output "  Attempt $i/30: Waiting for admin secret..."
  sleep 2
done

# ─────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────
log_output "${GREEN}=== ✓ GitOps Bootstrap Complete ===${NC}\n"

log_output "${YELLOW}Access ArgoCD (port-forward until DNS is set):${NC}"
log_output "  kubectl port-forward -n argocd svc/argocd-server 8080:80"
log_output "  Visit:    http://localhost:8080"
log_output "  Username: admin"
log_output "  Password: $ADMIN_PASSWORD"
log_output ""

log_output "${YELLOW}ArgoCD UI (once DNS argo.in.alybadawy.com → $SERVER_IP is set):${NC}"
log_output "  https://argo.in.alybadawy.com  (after wildcard cert is issued)"
log_output "  http://argo.in.alybadawy.com   (HTTP redirects to HTTPS once TLS is ready)"
log_output ""

log_output "${YELLOW}What happens next (automatic):${NC}"
log_output "  1. ArgoCD syncs root-app from $GIT_URL (k8s/root-app)"
log_output "  2. root-app creates argocd Application → ArgoCD self-manages"
log_output "  3. root-app creates nginx-ingress Application → ArgoCD manages controller"
log_output "  4. root-app creates reflector Application → mirrors TLS secrets across namespaces"
log_output "  5. root-app creates cert-manager Application → installs cert-manager + Vercel webhook"
log_output "  6. ClusterIssuer and wildcard Certificate created (*.in.alybadawy.com via DNS-01)"
log_output "  7. Let's Encrypt issues cert; reflector copies TLS secret to argocd namespace"
log_output "  8. ArgoCD Ingress switches to HTTPS at https://argo.in.alybadawy.com"
log_output ""

log_output "${YELLOW}Monitor sync:${NC}"
log_output "  kubectl get applications -n argocd"
log_output "  kubectl describe application root-app -n argocd"
log_output ""

log_output "${BLUE}Log saved to: $LOG_FILE${NC}\n"
