#!/usr/bin/env bash
#
# Phase 8: Install Longhorn and (optionally) restore PVC backups from NAS.
#
# Fresh cluster:  installs Longhorn, configures the NAS backup target, exits.
#                 Volumes will be created automatically when apps first deploy.
#
# Cluster rebuild: restores each backed-up volume from NAS and pre-creates PVCs
#                  so stateful apps bind to existing data instead of new empties.
#
# The Longhorn API is accessed via a temporary port-forward on localhost:9000.
# Backup target is the NFS share at NAS_IP/NAS_BASE_SHARE/backups (defaults.sh).
#
# Prerequisite: open-iscsi must be installed on the node (added to
#   update-dependencies in Phase 3). Longhorn uses it for block storage.
#
# Next step: provision/activate-gitops.sh
set -euo pipefail

LONGHORN_NAMESPACE="longhorn-system"
LONGHORN_API_PORT=9000
LONGHORN_API="http://localhost:${LONGHORN_API_PORT}/v1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

# shellcheck source=provision/lib/defaults.sh
source "$script_dir/lib/defaults.sh"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

BACKUP_TARGET="nfs://${NAS_IP}:${NAS_BASE_SHARE}/backups/pvcs"

# --- Preflight -------------------------------------------------------------
for bin in kubectl kustomize helm curl jq; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' is required but not on PATH."
done
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach a Kubernetes cluster (check KUBECONFIG)."

# --- 1. Install Longhorn ---------------------------------------------------
log "Creating namespace '$LONGHORN_NAMESPACE'"
kubectl get namespace "$LONGHORN_NAMESPACE" >/dev/null 2>&1 \
  || kubectl create namespace "$LONGHORN_NAMESPACE"

# The kustomization bundles CRD-dependent custom resources (BackupTarget,
# RecurringJob, PrometheusRule) in the same YAML stream as the Helm chart.
# kubectl apply aborts when it hits an unrecognised resource kind, so those
# resources are filtered out before the pipe reaches kubectl. They are applied
# directly after Longhorn is ready (PrometheusRule is left for ArgoCD — its
# CRDs come from the monitoring stack deployed in Phase 9).
log "Installing Longhorn from k8s/components/longhorn (Kustomize + Helm)"
kustomize build --enable-helm k8s/components/longhorn \
  | python3 -c "
import sys
docs = sys.stdin.read().split('\n---\n')
skip = {'BackupTarget', 'RecurringJob', 'PrometheusRule'}
print('\n---\n'.join(d for d in docs if not any('kind: ' + k in d for k in skip)))
" | kubectl apply --server-side --force-conflicts -f -

# --- 2. Wait for Longhorn --------------------------------------------------
# longhorn-manager is a DaemonSet (one pod per node), not a Deployment.
log "Waiting for Longhorn manager to become ready (this may take a few minutes)"
kubectl -n "$LONGHORN_NAMESPACE" rollout status daemonset/longhorn-manager --timeout=300s
kubectl -n "$LONGHORN_NAMESPACE" rollout status deploy/longhorn-ui         --timeout=120s

# Longhorn CRDs are now established — apply the custom resources directly.
# PrometheusRule is intentionally skipped (see comment above).
log "Applying Longhorn custom resources (BackupTarget, RecurringJob)"
kubectl apply -f k8s/components/longhorn/backup-target.yaml
kubectl apply -f k8s/components/longhorn/recurring-jobs.yaml

# --- 3. Fresh or restore? --------------------------------------------------
printf '\nIs this a fresh cluster with no backups to restore? [y/N] '
read -r FRESH_CLUSTER
if [[ "$FRESH_CLUSTER" =~ ^[Yy]$ ]]; then
  cat <<EOF

$(log "Longhorn installed (fresh mode). No volumes restored.")

Volumes will be created automatically when apps are first deployed.
Backup target configured: $BACKUP_TARGET

Access Longhorn UI:
  kubectl port-forward -n $LONGHORN_NAMESPACE svc/longhorn-frontend $LONGHORN_API_PORT:80
  open http://localhost:$LONGHORN_API_PORT

Next step: provision/activate-gitops.sh
EOF
  exit 0
fi

# --- 4. Start Longhorn API port-forward ------------------------------------
log "Starting Longhorn API port-forward on localhost:${LONGHORN_API_PORT}"
kubectl port-forward -n "$LONGHORN_NAMESPACE" \
  svc/longhorn-frontend "${LONGHORN_API_PORT}:80" &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Wait for the port-forward to be ready
for i in $(seq 1 15); do
  curl -sf "${LONGHORN_API}/volumes" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf "${LONGHORN_API}/volumes" >/dev/null 2>&1 \
  || fail "Longhorn API not reachable at ${LONGHORN_API} — is Longhorn fully up?"

# --- 5. Sync backup target ------------------------------------------------
log "Syncing backup target: $BACKUP_TARGET"
curl -s -X POST "${LONGHORN_API}/backuptargets/default?action=syncBackupTarget" \
  -H "Content-Type: application/json" -d '{}' >/dev/null || true

# --- 6. List available backup volumes -------------------------------------
# Poll until volumes appear or we time out (up to 3 minutes).
log "Waiting for backup catalog to load from NFS..."
BACKUP_VOLUMES_JSON=""
BACKUP_VOLUME_NAMES=""
for i in $(seq 1 18); do
  BACKUP_VOLUMES_JSON=$(curl -s "${LONGHORN_API}/backupvolumes")
  BACKUP_VOLUME_NAMES=$(echo "$BACKUP_VOLUMES_JSON" | jq -r '.data[].name // empty')
  [[ -n "$BACKUP_VOLUME_NAMES" ]] && break
  printf '  attempt %d/18 — no volumes yet, retrying in 10s...\n' "$i"
  sleep 10
done

if [[ -z "$BACKUP_VOLUME_NAMES" ]]; then
  warn "No backup volumes found at $BACKUP_TARGET after 3 minutes."
  warn "Check the Longhorn UI: kubectl port-forward -n $LONGHORN_NAMESPACE svc/longhorn-frontend 9001:80"
  warn "Verify the backup target is reachable and backups exist on the NAS share."
  exit 1
fi

log "Found backup volumes:"
while IFS= read -r bvol; do
  SIZE=$(echo "$BACKUP_VOLUMES_JSON" \
    | jq -r --arg n "$bvol" '.data[] | select(.name==$n) | .size')
  SIZE_GI=$(( (SIZE + 1073741823) / 1073741824 ))
  [[ $SIZE_GI -lt 1 ]] && SIZE_GI=1
  printf '  %-40s  %sGi\n' "$bvol" "$SIZE_GI"
done <<< "$BACKUP_VOLUME_NAMES"
echo

# --- 7. Restore each volume -----------------------------------------------
declare -a RESTORED=()

while IFS= read -r BACKUP_VOL; do
  [[ -z "$BACKUP_VOL" ]] && continue

  log "Restoring: $BACKUP_VOL"

  # Get the latest backup URL for this volume
  LATEST_BACKUP=$(curl -s "${LONGHORN_API}/backupvolumes/${BACKUP_VOL}/backups" \
    | jq -r '.data | sort_by(.created) | last | .url')
  if [[ -z "$LATEST_BACKUP" || "$LATEST_BACKUP" == "null" ]]; then
    warn "  No backups found for $BACKUP_VOL — skipping"
    continue
  fi

  # Calculate size in Gi (round up, minimum 1Gi)
  SIZE_BYTES=$(echo "$BACKUP_VOLUMES_JSON" \
    | jq -r --arg n "$BACKUP_VOL" '.data[] | select(.name==$n) | .size')
  SIZE_GI=$(( (SIZE_BYTES + 1073741823) / 1073741824 ))
  [[ $SIZE_GI -lt 1 ]] && SIZE_GI=1

  # Ask where this PVC should live
  printf '  Namespace for "%s" [e.g. vaultwarden]: ' "$BACKUP_VOL"
  read -r TARGET_NS
  printf '  PVC name for "%s" [e.g. vaultwarden-data]: ' "$BACKUP_VOL"
  read -r PVC_NAME
  if [[ -z "$TARGET_NS" || -z "$PVC_NAME" ]]; then
    warn "  Skipping $BACKUP_VOL — no namespace/PVC name provided"
    continue
  fi

  LONGHORN_VOL_NAME="${PVC_NAME}-restored"
  PV_NAME="${PVC_NAME}-pv"

  # Create Longhorn volume from backup
  log "  Creating Longhorn volume '$LONGHORN_VOL_NAME' from backup"
  curl -s -X POST "${LONGHORN_API}/volumes" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$LONGHORN_VOL_NAME\",
      \"fromBackup\": \"$LATEST_BACKUP\",
      \"numberOfReplicas\": 1
    }" >/dev/null

  # Wait for restore to reach 'detached' state (up to 5 minutes)
  log "  Waiting for restore to complete..."
  RESTORE_DONE=false
  for i in $(seq 1 60); do
    STATE=$(curl -s "${LONGHORN_API}/volumes/${LONGHORN_VOL_NAME}" \
      | jq -r '.state // "unknown"')
    if [[ "$STATE" == "detached" ]]; then
      RESTORE_DONE=true
      break
    fi
    sleep 5
  done
  if [[ "$RESTORE_DONE" != "true" ]]; then
    warn "  Restore of $LONGHORN_VOL_NAME did not complete in time — skipping PVC creation"
    continue
  fi

  # Create namespace if needed
  kubectl get namespace "$TARGET_NS" >/dev/null 2>&1 \
    || kubectl create namespace "$TARGET_NS"

  # Create PV + PVC pre-bound to the restored Longhorn volume
  log "  Creating PV '$PV_NAME' and PVC '$PVC_NAME' in namespace '$TARGET_NS'"
  kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
spec:
  capacity:
    storage: ${SIZE_GI}Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: $LONGHORN_VOL_NAME
---
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
      storage: ${SIZE_GI}Gi
MANIFEST

  RESTORED+=("$TARGET_NS/$PVC_NAME  →  longhorn volume: $LONGHORN_VOL_NAME")
done <<< "$BACKUP_VOLUME_NAMES"

# --- 8. Summary -----------------------------------------------------------
cat <<EOF

$(log "Longhorn restore complete.")

Restored PVCs:
EOF
if [[ ${#RESTORED[@]} -eq 0 ]]; then
  echo "  (none)"
else
  for entry in "${RESTORED[@]}"; do
    echo "  $entry"
  done
fi
cat <<EOF

These PVCs are pre-bound. When GitOps deploys stateful apps they will attach
to the restored data instead of creating new empty volumes.

Access Longhorn UI:
  kubectl port-forward -n $LONGHORN_NAMESPACE svc/longhorn-frontend $LONGHORN_API_PORT:80
  open http://localhost:$LONGHORN_API_PORT

Next step: provision/activate-gitops.sh
EOF
