#!/usr/bin/env bash
#
# Phase 9: Activate GitOps — apply the root app-of-apps and hand full cluster
# ownership to ArgoCD.
#
# After this runs:
#   • ArgoCD self-manages (adopts the bootstrapped install with no diff)
#   • Longhorn self-manages (adopts the bootstrapped install with no diff)
#   • All other apps in k8s/apps/ are deployed and kept in sync from Git
#   • Stateful apps bind to PVCs pre-created by restore-volumes.sh
#
# Prerequisites:
#   provision/bootstrap-argocd.sh  — ArgoCD must be running
#   provision/restore-volumes.sh   — Longhorn must be running; PVCs restored
set -euo pipefail

ARGOCD_NAMESPACE="argocd"
REPO_REVISION="${REPO_REVISION:-main}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || fail "'kubectl' is required but not on PATH."
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach a Kubernetes cluster (check KUBECONFIG)."

kubectl -n "$ARGOCD_NAMESPACE" get deploy/argocd-server >/dev/null 2>&1 \
  || fail "ArgoCD not found in namespace '$ARGOCD_NAMESPACE'. Run bootstrap-argocd.sh first."
kubectl -n longhorn-system get daemonset/longhorn-manager >/dev/null 2>&1 \
  || fail "Longhorn not found in namespace 'longhorn-system'. Run restore-volumes.sh first."

# --- Apply root app-of-apps -----------------------------------------------
log "Revision : $REPO_REVISION"
log "Applying root app-of-apps (k8s/apps/root.yaml)"
sed -e "s|^\( *targetRevision: \).*|\1$REPO_REVISION|g" \
    k8s/apps/root.yaml \
  | kubectl apply -f -

# --- Done ------------------------------------------------------------------
cat <<EOF

$(log "GitOps activated.")

ArgoCD will now discover and sync all applications in k8s/apps/.
Infrastructure apps (argocd, longhorn, ingress-nginx, cert-manager) will be
adopted with no diff. Stateful apps will bind to pre-existing PVCs.

Watch the rollout:
  kubectl get applications -n $ARGOCD_NAMESPACE -w

Initial admin password (delete the secret after rotating):
  kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 -d; echo

Open the ArgoCD UI (once ingress-nginx syncs and DNS resolves):
  https://argo.in.alybadawy.com
  or: kubectl port-forward -n $ARGOCD_NAMESPACE svc/argocd-server 8080:80
EOF
