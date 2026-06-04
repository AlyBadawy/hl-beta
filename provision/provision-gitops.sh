#!/usr/bin/env bash
#
# Bootstraps ArgoCD onto a fresh k3s cluster and hands the cluster over to
# GitOps. After this runs, ArgoCD manages every component — and itself — from
# the Git repo.
#
# Flow:
#   1. Install ArgoCD imperatively from k8s/components/argocd (Kustomize + Helm).
#   2. Wait for argocd-server to be ready.
#   3. Apply the root "app of apps" Application from k8s/root/root-app.yaml.
#   4. ArgoCD discovers the child apps, including one that tracks k8s/components/argocd
#      itself, and adopts the running ArgoCD with no diff -> self-management.
set -euo pipefail

ARGOCD_NAMESPACE="argocd"
REPO_URL="https://github.com/AlyBadawy/hl-beta"
REPO_REVISION="${REPO_REVISION:-main}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
for bin in kubectl kustomize helm; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' is required but not on PATH."
done
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach a Kubernetes cluster (check KUBECONFIG)."

log "Repo URL : $REPO_URL"
log "Revision : $REPO_REVISION"

# Prompt for Cloudflare API token (DNS-01 challenge for cert-manager).
# The token needs Zone:DNS:Edit permissions for the domain zone.
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  read -rsp "Cloudflare API token (Zone:DNS:Edit): " CLOUDFLARE_API_TOKEN; echo
  [[ -n "$CLOUDFLARE_API_TOKEN" ]] || fail "Cloudflare API token is required."
fi

# --- 1. Install ArgoCD imperatively ---------------------------------------
log "Creating namespace '$ARGOCD_NAMESPACE'"
kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
  || kubectl create namespace "$ARGOCD_NAMESPACE"

log "Installing ArgoCD from k8s/components/argocd (Kustomize + Helm)"
kustomize build --enable-helm k8s/components/argocd \
  | kubectl apply --server-side --force-conflicts -f -

# --- 2. Wait for ArgoCD to come up ----------------------------------------
log "Waiting for ArgoCD to become ready"
kubectl -n "$ARGOCD_NAMESPACE" rollout status deploy/argocd-server      --timeout=300s
kubectl -n "$ARGOCD_NAMESPACE" rollout status deploy/argocd-repo-server --timeout=300s

# --- 3. Create cert-manager Cloudflare token secret -----------------------
log "Creating cert-manager namespace and Cloudflare API token secret"
kubectl get namespace cert-manager >/dev/null 2>&1 \
  || kubectl create namespace cert-manager
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 4. Apply the root app -------------------------------------------------
log "Applying the root 'app of apps' Application"
sed -e "s|^\( *targetRevision: \).*|\1$REPO_REVISION|g" \
    k8s/root/root-app.yaml \
  | kubectl apply -f -

# --- 5. Done ---------------------------------------------------------------
cat <<EOF

$(log "Bootstrap complete.")

ArgoCD is now self-managing. The imperatively-installed ArgoCD has been adopted
by the 'argocd' Application; all future changes flow through Git.

Watch the rollout:
  kubectl get applications -n $ARGOCD_NAMESPACE -w

Initial admin password (delete the secret after you log in and rotate it):
  kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 -d; echo

Then open the ArgoCD UI at the host configured in k8s/components/argocd/values.yaml.
EOF
