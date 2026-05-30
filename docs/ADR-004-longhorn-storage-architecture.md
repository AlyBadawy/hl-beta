# ADR-004: Longhorn Storage Architecture

**Status:** Accepted  
**Date:** 2026-05-30  
**Context:** Phase 8 — Adding distributed storage to k3s cluster

## Problem

The cluster needs persistent storage for stateful applications. Without distributed storage, data is tied to node-specific paths, making workload portability and redundancy difficult. However, the single-node architecture limits the benefits of data replication.

## Decision

1. **Install Longhorn v1.7.2** as the distributed storage provider
2. **Keep local-path as default storage class** — most workloads use local storage
3. **Configure Longhorn for single-node operation** — no data replication
4. **Set up NFS backup target** on NAS for disaster recovery
5. **Manage Longhorn via two ArgoCD Applications** with sync wave separation:
   - **Wave 3:** Longhorn Helm chart (installs CRDs, operator, UI)
   - **Wave 4:** Longhorn configuration (ingress, backup jobs)

## Rationale

### Why Longhorn?

- Open-source, Kubernetes-native storage orchestrator
- Lightweight; suitable for homelab single-node clusters
- Built-in backup/snapshot capabilities via NFS
- CRD-based; integrates well with ArgoCD
- Active community and good documentation

### Single-Node Configuration

On a single-node cluster, data replication provides no benefit and wastes resources. Instead:

- `defaultReplicaCount: 1` — only one copy of data (on the single node)
- `defaultDataLocality: best-effort` — place data on the node where pod runs (irrelevant with one node, but follows best practices)
- `replicaAutoBalance: disabled` — no need to balance replicas
- Metrics collection disabled for single-node

### Local-Path Remains Default

Most workloads (e.g., databases with their own replication, caches) don't need Longhorn. Using local-path as default:
- Reduces storage overhead
- Faster I/O for workloads that don't need redundancy
- Simplifies debugging (no storage controller in the critical path)

**Applications that need Longhorn must explicitly request it:**
```yaml
persistentVolumeClaim:
  storageClassName: longhorn
```

### NFS Backup Target on NAS

Backups decouple data from the cluster node. Using NAS:
- Centralized backup storage (survives cluster failure)
- NFSv3 with nolock option (stateless locking, safe for backups, compatible with NAS)
- Path on NAS: `/var/nfs/shared/backups/k3s-longhorn`

Backup strategy:
- Snapshots every 6 hours (in-cluster, fast, for crash recovery)
- Backups every 6 hours (30-min offset from snapshots, to NAS, for disaster recovery)
- Retain 30 snapshots and 30 backups

### Two-Wave Application Architecture

**Wave 3: infra-longhorn (Helm)**
- Installs Longhorn Helm chart
- Creates `longhorn-system` namespace
- Deploys operator, engine, UI pods
- Defines CustomResourceDefinitions (CRDs) for Volumes, Snapshots, etc.

**Wave 4: infra-longhorn-config (Kustomize)**
- Depends on Wave 3 (CRDs must exist)
- Manages Ingress for Longhorn UI
- Defines RecurringJob CRs for snapshots and backups
- Uses kustomize-envsubst plugin to substitute domain from cluster-config

**Why separate waves?**

RecurringJob CRs require the Longhorn CRDs to exist. Separating the Helm install (wave 3) from the config (wave 4) ensures ArgoCD waits for CRDs before creating RecurringJobs.

### ArgoCD Ingress Configuration

The Longhorn Ingress is a plain Kubernetes manifest (not Helm-managed), allowing:
- Single source of truth in git (`git-ops/infrastructure/longhorn/ingress.yaml`)
- Simple variable substitution via kustomize-envsubst
- No duplication between bootstrap and GitOps phases

Ingress resolves to `longhorn.{{ domain }}` (e.g., `longhorn.in.alybadawy.com`).

### Variable Substitution Strategy

**Problem:** Avoid hardcoding NAS IP and domain in manifests.

**Solution:** Use kustomize-envsubst plugin to substitute:
- `${NAS_IP}` — from cluster-config, injected at render time
- `${NAS_BASE_SHARE}` — from cluster-config
- `${DOMAIN}` — from cluster-config

Helm parameters in the Application also use the same syntax:
```yaml
parameters:
  - name: defaultSettings.backupTarget
    value: "nfs://${NAS_IP}:${NAS_BASE_SHARE}/backups/k3s-longhorn?nfsOptions=..."
```

### Longhorn Resource Self-Modifications

Longhorn modifies its own resources at runtime (e.g., default settings ConfigMap). ArgoCD would see these as drift and mark the application OutOfSync. The Application uses `ignoreDifferences` to prevent this:

```yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: longhorn-default-setting
    namespace: longhorn-system
    jsonPointers:
      - /data
```

This tells ArgoCD to ignore changes to the ConfigMap data, since Longhorn manages it at runtime.

## Consequences

### Positive

- Disaster recovery via NAS backups (independent of cluster node)
- UI accessible at `longhorn.{{ domain }}` for monitoring/management
- Workloads explicitly declare need for Longhorn, making dependencies clear
- Synced backups provide recovery point for critical data

### Negative

- Single point of failure if node fails (no replication)
- Longhorn operator is another component to monitor
- NFS dependency: backups fail if NAS is down

### Mitigation

- Keep NAS available and monitored (separate homelab infrastructure concern)
- Monitor Longhorn operator logs for errors
- Test backup/restore procedures regularly
- Use local-path for non-critical workloads to reduce Longhorn load

## Alternatives Considered

### 1. No Distributed Storage (Local-Path Only)

**Rejected:** No backup/disaster recovery path; workload mobility limited.

### 2. Ceph (Rook-Ceph)

**Rejected:** Too heavy for single-node; overkill for homelab. Longhorn is more lightweight.

### 3. Single-Wave Longhorn Application

**Rejected:** Risk of applying RecurringJob CRs before CRDs exist, causing transient sync failures. Two waves are simpler and more reliable.

## Related Decisions

- **ADR-003:** GitOps ownership and multi-source Applications
- **Phase 7:** Bootstrap uses simplified Helm values; GitOps phase takes over full configuration

---

**Next Steps:**

1. Verify cluster-config is populated with NAS IP and domain
2. Deploy Longhorn via provision script Phase 8 (GitOps apply)
3. Test backup/restore workflow
4. Document backup/restore runbook in `docs/runbooks/`
