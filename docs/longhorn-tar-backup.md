# Longhorn Volume Tar Backup

**Date:** 2026-06-06

Longhorn already snapshots and backs up PVCs to the NAS every 6 hours
(`172.20.20.2:/var/nfs/shared/backups/pvcs`), but that format is Longhorn-specific and
requires Longhorn to restore. This document describes how to additionally export raw PVC
filesystem contents as portable `.tar.gz` files — useful for off-cluster restores,
inspecting data, or archiving independent of Longhorn.

---

## How It Works

A temporary Kubernetes Job mounts each PVC read-only and runs `tar` inside the cluster.
The output files are written to `/mnt/nas/backups/tar-backups/` via a `hostPath` volume
(the NAS is already mounted at `/mnt/nas/` on the k3s node).

On a single-node cluster, multiple pods can share a `ReadWriteOnce` PVC on the same node,
so backup Jobs run alongside live application pods — **no application shutdown required**.
The backup is live (not crash-consistent); databases should use their own dump mechanism
(see the PostgreSQL logical backup CronJob) rather than relying on this.

---

## Script: `provision/backup-volumes-tar.sh`

This script needs to be created. Here is the full implementation:

```bash
#!/usr/bin/env bash
#
# Ad-hoc backup: export each Longhorn PVC's filesystem as a tar.gz to the NAS.
#
# Output: /mnt/nas/backups/tar-backups/{namespace}-{pvc}-{timestamp}.tar.gz
#
# Safe to run while apps are live (single-node: RWO PVCs can be shared on same node).
# For database PVCs, prefer pg_dump / mysqldump over this raw filesystem backup.
#
# Usage: ./provision/backup-volumes-tar.sh
set -euo pipefail

LONGHORN_SC="longhorn"
JOB_TIMEOUT=300   # seconds to wait per volume

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

# shellcheck source=provision/lib/defaults.sh
source "$script_dir/lib/defaults.sh"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

TAR_BACKUP_DIR="${NAS_BASE_MOUNT}/backups/tar-backups"

# --- Preflight ----------------------------------------------------------------
for bin in kubectl jq ssh xxd; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' is required but not on PATH."
done
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach a Kubernetes cluster (check KUBECONFIG)."

require_server_ip

# --- Ensure output directory exists on node -----------------------------------
log "Ensuring output directory exists on server: $TAR_BACKUP_DIR"
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=QUIET \
    "${SSH_USER}@${SERVER_IP}" \
    "sudo mkdir -p '$TAR_BACKUP_DIR' && sudo chmod 755 '$TAR_BACKUP_DIR'"

# --- Discover Longhorn PVCs ---------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
log "Discovering bound Longhorn PVCs..."

mapfile -t PVCS < <(
  kubectl get pvc -A -o json \
    | jq -r --arg sc "$LONGHORN_SC" '
        .items[]
        | select(.spec.storageClassName == $sc)
        | select(.status.phase == "Bound")
        | [.metadata.namespace, .metadata.name]
        | @tsv'
)

if [[ ${#PVCS[@]} -eq 0 ]]; then
  warn "No bound Longhorn PVCs found. Nothing to back up."
  exit 0
fi

log "Found ${#PVCS[@]} PVC(s) to back up."

declare -a SUCCEEDED=()
declare -a FAILED=()

# --- Backup loop --------------------------------------------------------------
for entry in "${PVCS[@]}"; do
  NS=$(echo "$entry" | cut -f1)
  PVC_NAME=$(echo "$entry" | cut -f2)
  OUTFILE="${NS}-${PVC_NAME}-${TIMESTAMP}.tar.gz"
  RAND=$(head -c 4 /dev/urandom | xxd -p | tr -d '\n')
  JOB_NAME="pvc-backup-${RAND}"

  log "Backing up: ${NS}/${PVC_NAME} → ${OUTFILE}"

  # Warn if PVC is actively mounted
  ACTIVE_PODS=$(kubectl get pods -n "$NS" -o json \
    | jq -r --arg pvc "$PVC_NAME" \
      '[.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc)
        | .metadata.name] | join(", ")')
  if [[ -n "$ACTIVE_PODS" ]]; then
    warn "  PVC is in use by: $ACTIVE_PODS — backup is live (not crash-consistent)"
  fi

  # Apply Job
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: backup-volumes-tar
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: tar
          image: busybox:stable
          command:
            - sh
            - -c
            - tar czf /backup/${OUTFILE} -C /data . && echo "done: ${OUTFILE}"
          volumeMounts:
            - name: data
              mountPath: /data
              readOnly: true
            - name: backup
              mountPath: /backup
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
            readOnly: true
        - name: backup
          hostPath:
            path: ${TAR_BACKUP_DIR}
            type: DirectoryOrCreate
EOF

  # Wait for completion
  RESULT="timeout"
  elapsed=0
  while (( elapsed < JOB_TIMEOUT )); do
    conditions=$(kubectl get job "$JOB_NAME" -n "$NS" \
      -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
    if echo "$conditions" | jq -e '.[] | select(.type=="Complete" and .status=="True")' >/dev/null 2>&1; then
      RESULT="ok"; break
    fi
    if echo "$conditions" | jq -e '.[] | select(.type=="Failed" and .status=="True")' >/dev/null 2>&1; then
      RESULT="failed"; break
    fi
    sleep 5
    (( elapsed += 5 ))
  done

  # Capture logs on failure
  if [[ "$RESULT" != "ok" ]]; then
    POD_NAME=$(kubectl get pods -n "$NS" \
      -l "job-name=${JOB_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$POD_NAME" ]]; then
      warn "  Pod logs:"
      kubectl logs -n "$NS" "$POD_NAME" 2>/dev/null | sed 's/^/    /' || true
    fi
  fi

  # Cleanup
  kubectl delete job "$JOB_NAME" -n "$NS" --ignore-not-found=true >/dev/null 2>&1 || true

  if [[ "$RESULT" == "ok" ]]; then
    log "  ✓ ${OUTFILE}"
    SUCCEEDED+=("${NS}/${PVC_NAME}  →  ${OUTFILE}")
  else
    warn "  ✗ ${NS}/${PVC_NAME} (${RESULT})"
    FAILED+=("${NS}/${PVC_NAME} (${RESULT})")
  fi
done

# --- Summary ------------------------------------------------------------------
echo
log "Tar backup complete."
echo
echo "Succeeded (${#SUCCEEDED[@]}):"
for e in "${SUCCEEDED[@]:-}"; do [[ -n "$e" ]] && echo "  $e"; done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "Failed (${#FAILED[@]}):"
  for e in "${FAILED[@]}"; do echo "  $e"; done
fi

echo
echo "Output on NAS: /var/nfs/shared/backups/tar-backups/"
```

---

## Running It

```bash
# From the repo root
./provision/backup-volumes-tar.sh
# Enter SERVER_IP when prompted (e.g. 192.168.1.100)
```

---

## Output Location

| Path on server          | `$TAR_BACKUP_DIR` = `/mnt/nas/backups/tar-backups/`     |
| ----------------------- | ------------------------------------------------------- |
| Path on NAS             | `/var/nfs/shared/backups/tar-backups/`                  |
| Filename format         | `{namespace}-{pvc-name}-{YYYYMMDD-HHMMSS}.tar.gz`       |

---

## Verifying a Backup

```bash
# List contents without extracting
tar tzf /mnt/nas/backups/tar-backups/<name>.tar.gz | head -20

# Check no Jobs were left behind
kubectl get jobs -A -l app.kubernetes.io/managed-by=backup-volumes-tar

# Confirm apps still running
kubectl get pods -A | grep -v -E 'Running|Completed'
```

---

## Caveats

- **Live backup:** The tar runs against a mounted live filesystem. For databases, a
  filesystem-level backup is not sufficient — prefer `pg_dump` (already handled by the
  PostgreSQL logical backup CronJob).
- **No deduplication:** Each run writes a full copy. Tar files accumulate on the NAS;
  prune old backups manually or add a retention step.
- **Longhorn backups are separate:** This script complements, not replaces, Longhorn's
  built-in NFS backup mechanism.
