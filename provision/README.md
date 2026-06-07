# Provisioning

Automated provisioning scripts for k3s cluster setup.

## Quick Start

```bash
# Server setup (Phases 2–6)
./provision/provision-server.sh

# GitOps bootstrap (Phases 7–9) — run in order:
./provision/bootstrap-argocd.sh    # Phase 7: install ArgoCD
./provision/restore-volumes.sh     # Phase 8: install Longhorn + restore PVCs
./provision/activate-gitops.sh     # Phase 9: apply app-of-apps, GitOps takes over
```

**Why three GitOps scripts?**
The split creates a safe window between ArgoCD being up (Phase 7) and apps being
deployed (Phase 9). Phase 8 uses that window to restore Longhorn PVC backups from
NAS so stateful apps bind to existing data instead of creating new empty volumes.

## Configuration

All static values live in [`lib/defaults.sh`](lib/defaults.sh) and can be overridden
by exporting an environment variable before running:

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | `homelab` | SSH user on the target server |
| `NAS_IP` | `172.20.20.2` | NAS server IP |
| `NAS_BASE_SHARE` | `/var/nfs/shared` | NFS export path on NAS |
| `NAS_BASE_MOUNT` | `/mnt/nas` | Local mount point |
| `ADMIN_EMAIL` | `alybadawy@icloud.com` | Admin notification email |
| `DOMAIN` | `in.alybadawy.com` | Base domain for the cluster |
| `GIT_REPO` | `https://github.com/AlyBadawy/hl-beta` | GitOps repository URL |

**Prompted at runtime:**
- `SERVER_IP` — prompted once at the top of `provision-server.sh`
- `CLOUDFLARE_API_TOKEN` — prompted by `bootstrap-argocd.sh` (Phase 7)
- `REPO_REVISION` — defaults to `main`; export to override before running Phase 7–9

## Provisioning Phases

### Phase 2: `check-ssh-connection`

Validates SSH connectivity and NOPASSWD sudo access to the target server.

### Phase 3: `update-dependencies`

Updates packages and installs essentials (curl, wget, git, jq, nfs-common, open-iscsi,
apparmor, socat, etc.), disables SWAP, and installs Helm.
`open-iscsi` is required by Longhorn for block storage PVCs (Phase 8).

### Phase 4: `mount-nas`

Configures NFS mounts for `/mnt/nas/{homelab,backups,immich,nextcloud}` via `/etc/fstab`.
Idempotent — safe to re-run.

### Phase 5: `install-k3s`

Installs k3s `v1.36.1+k3s1` with Traefik disabled, waits for readiness, and copies
kubeconfig locally to `~/.kube/config`.

### Phase 6: `configure-cluster`

Creates a `cluster-config` namespace and ConfigMap (domain, NAS paths, admin email,
server IP) in the cluster. Applies kernel tuning (`inotify`, `vm.max_map_count`).

### Phase 7: `bootstrap-argocd.sh`

Installs ArgoCD via Kustomize + Helm (`k8s/components/argocd`), waits for it to be
ready, and creates the cert-manager Cloudflare API token secret. **No applications
are deployed yet** — that gate is held open for Phase 8.

### Phase 8: `restore-volumes.sh`

Installs Longhorn via Kustomize + Helm (`k8s/components/longhorn`) with the NAS NFS
share configured as the backup target.

- **Fresh cluster:** exits immediately after install; volumes are created on first use.
- **Cluster rebuild:** uses the Longhorn REST API (via port-forward) to restore each
  backup volume from NAS, then pre-creates matching PVs and PVCs so stateful apps bind
  to restored data when they start in Phase 9.

### Phase 9: `activate-gitops.sh`

Applies the root app-of-apps (`k8s/apps/root.yaml`). ArgoCD discovers all child apps
and adopts the imperatively-installed ArgoCD and Longhorn with no diff, then deploys
the rest of the stack. Git (main branch) becomes the sole source of truth.

## Helper Library

### `lib/defaults.sh`

Defines all hardcoded homelab values and the `require_server_ip` helper. All
sub-scripts source this file. The Longhorn backup target in
`k8s/components/longhorn/values.yaml` must match `NAS_IP` and `NAS_BASE_SHARE` here.
