#!/usr/bin/env bash
#
# Migrate PVCs from old namespaces (vaultwarden, auth) to the security namespace
# by rebinding existing Longhorn PVs — no data is copied or restored from backup.
#
# Run AFTER the namespace refactor has been pushed and ArgoCD has synced
# (so the security namespace and its freshly provisioned empty PVCs exist).
#
# Flow:
#   1. Scale down apps in old namespaces and security namespace
#   2. For each PVC: patch PV reclaim policy → Retain, delete old PVC, clear claimRef
#   3. Delete the empty PVCs ArgoCD created in security namespace
#   4. Create pre-bound PVCs in security namespace pointing at the existing PVs
#   5. ArgoCD selfHeal rescales the apps automatically once PVCs are bound
#
# After this script succeeds, delete old namespaces:
#   kubectl delete namespace vaultwarden auth cert-manager ingress-nginx whoami
set -euo pipefail

TARGET_NS="security"

# "old-namespace:pvc-name:size"
PVCS=(
  "vaultwarden:vaultwarden-data-lh:5Gi"
  "auth:authentik-data-lh:5Gi"
  "auth:authentik-templates-lh:1Gi"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight ----------------------------------------------------------------
for bin in kubectl; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' is required but not on PATH."
done
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach cluster (check KUBECONFIG)."

log "PVC migration: vaultwarden + auth namespaces → $TARGET_NS"
echo
echo "This script will:"
echo "  1. Scale down apps in vaultwarden, auth, and security namespaces"
echo "  2. Rebind the existing Longhorn PVs to new PVCs in 'security'"
echo "  No data is copied — the underlying Longhorn volumes are reused directly."
echo
printf 'Proceed? [y/N] '
read -r CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- 1. Scale down apps in all affected namespaces ----------------------------
log "Scaling down deployments in old namespaces and $TARGET_NS"
for ns in vaultwarden auth "$TARGET_NS"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    if kubectl get deploy -n "$ns" --no-headers 2>/dev/null | grep -q .; then
      kubectl scale deploy -n "$ns" --all --replicas=0
      log "  Scaled down all deployments in $ns"
    fi
  fi
done

log "Waiting for pods to terminate (up to 2 minutes)..."
for ns in vaultwarden auth "$TARGET_NS"; do
  kubectl wait pod --all -n "$ns" --for=delete --timeout=120s 2>/dev/null || true
done

# --- 2. Migrate each PVC ------------------------------------------------------
declare -a MIGRATED=()
declare -a FAILED=()

for entry in "${PVCS[@]}"; do
  IFS=':' read -r OLD_NS PVC_NAME SIZE <<< "$entry"

  log "Migrating $OLD_NS/$PVC_NAME → $TARGET_NS/$PVC_NAME"

  # Find the PV bound to the old PVC
  PV_NAME=$(kubectl get pvc "$PVC_NAME" -n "$OLD_NS" \
    -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
  if [[ -z "$PV_NAME" ]]; then
    warn "  PVC $OLD_NS/$PVC_NAME not found or not bound — skipping"
    FAILED+=("$OLD_NS/$PVC_NAME (not found)")
    continue
  fi
  log "  Bound PV: $PV_NAME"

  # Patch PV to Retain so deleting the PVC doesn't destroy the volume
  kubectl patch pv "$PV_NAME" \
    -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
  log "  Patched PV reclaim policy → Retain"

  # Delete the old PVC — PV moves to Released state, Longhorn volume is kept
  kubectl delete pvc "$PVC_NAME" -n "$OLD_NS"
  log "  Deleted old PVC (PV now Released)"

  # Remove claimRef so the PV becomes Available again
  kubectl patch pv "$PV_NAME" --type=json \
    -p '[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null
  log "  Cleared PV claimRef → Available"

  # Delete the empty PVC ArgoCD provisioned in security namespace (if it exists)
  if kubectl get pvc "$PVC_NAME" -n "$TARGET_NS" >/dev/null 2>&1; then
    kubectl delete pvc "$PVC_NAME" -n "$TARGET_NS"
    log "  Deleted empty PVC in $TARGET_NS (ArgoCD-provisioned)"
  fi

  # Create the pre-bound PVC in security, pointing at the existing PV
  kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $TARGET_NS
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  volumeName: $PV_NAME
  resources:
    requests:
      storage: $SIZE
MANIFEST
  log "  Created new PVC $TARGET_NS/$PVC_NAME → $PV_NAME"

  # Wait for the PVC to bind (up to 60s)
  BOUND=false
  for i in $(seq 1 30); do
    STATUS=$(kubectl get pvc "$PVC_NAME" -n "$TARGET_NS" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$STATUS" == "Bound" ]]; then
      BOUND=true
      break
    fi
    sleep 2
  done

  if [[ "$BOUND" == "true" ]]; then
    log "  PVC bound successfully"
    MIGRATED+=("$TARGET_NS/$PVC_NAME → PV $PV_NAME")
  else
    warn "  PVC did not bind within 60s (status: $STATUS)"
    warn "  Check: kubectl get pvc $PVC_NAME -n $TARGET_NS"
    warn "  Check: kubectl describe pv $PV_NAME"
    FAILED+=("$TARGET_NS/$PVC_NAME (not bound)")
  fi
done

# --- Summary ------------------------------------------------------------------
echo
log "Migration complete."
echo
echo "Migrated PVCs:"
if [[ ${#MIGRATED[@]} -eq 0 ]]; then
  echo "  (none)"
else
  for e in "${MIGRATED[@]}"; do echo "  $e"; done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  warn "Failed / skipped:"
  for e in "${FAILED[@]}"; do echo "  $e"; done
fi

cat <<EOF

ArgoCD selfHeal will automatically scale the apps back up once the PVCs are bound.
Monitor progress:
  kubectl get pods -n security -w

Once apps are healthy, delete the old orphaned namespaces:
  kubectl delete namespace vaultwarden auth cert-manager ingress-nginx whoami
EOF
