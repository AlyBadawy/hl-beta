# Provisioning

Automated provisioning scripts for k3s cluster setup.

## Quick Start

```bash
# Full rebuild: provisions server, seeds secrets, bootstraps ArgoCD
./provision/rebuild.sh

# Activate GitOps once you've verified everything from rebuild.sh looks good
./provision/activate-gitops.sh
```

**Why is activate-gitops.sh separate?**
`rebuild.sh` deliberately stops after bootstrapping ArgoCD so you can do a final
sanity check — verify both secrets are present and confirm ArgoCD is healthy —
before handing full cluster control to ArgoCD.

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

**Prompted at runtime (by `rebuild.sh`):**
- `SERVER_IP` — new node's IP address
- `VAULT_UNSEAL_KEY` — from offline backup / password manager
- `CLOUDFLARE_API_TOKEN` — Zone:DNS:Edit for `alybadawy.com`
- `REPO_REVISION` — defaults to `main`; export to override before running

## Steps

### Step 1: `check-ssh-connection`

Validates SSH connectivity and NOPASSWD sudo access to the target server.

### Step 2: `update-dependencies`

Updates packages and installs essentials (curl, wget, git, jq, nfs-common,
apparmor, socat, etc.), disables SWAP, and installs Helm.

### Step 3: `mount-nas`

Configures NFS mounts for `/mnt/nas/{homelab,backups}` via `/etc/fstab`.
Idempotent — safe to re-run.

### Step 4: `install-k3s`

Installs k3s `v1.36.1+k3s1` with Traefik disabled, waits for readiness, and copies
kubeconfig locally to `~/.kube/config`.

### Step 5: `configure-cluster`

Creates a `cluster-config` namespace and ConfigMap (domain, NAS paths, admin email,
server IP) in the cluster. Applies kernel tuning (`inotify`, `vm.max_map_count`).

### Step 6: Seed Vault unseal key

Handled inline by `rebuild.sh` — creates the `security` namespace and seeds the
`vault-unseal-key` secret from the value you entered at the start. This must exist
before GitOps activates so the `vault-auto-unseal` CronJob can unseal Vault on boot.

### Step 7: `bootstrap-argocd`

Installs ArgoCD via Kustomize + Helm (`k8s/components/argocd`), waits for it to be
ready, and creates the cert-manager Cloudflare API token secret. **No applications
are deployed yet** — that gate is held open for the final manual sanity check
before `activate-gitops.sh`.

### Final step: `activate-gitops.sh`

Applies the root app-of-apps (`k8s/apps/root.yaml`). ArgoCD discovers all child apps
and adopts the imperatively-installed ArgoCD with no diff, then deploys the rest of
the stack — stateful apps bind to NFS PersistentVolumes pointing at already-persistent
data on the NAS, no restore step needed. Git (main branch) becomes the sole source of
truth.

## Helper Library

### `lib/defaults.sh`

Defines all hardcoded homelab values and the `require_server_ip` helper. All
sub-scripts source this file. Every NFS-backed `PersistentVolume` under
`k8s/components/*/` (e.g. `*-pv.yaml`) references `NAS_IP` and the NAS export
path directly, so they must stay consistent with `NAS_BASE_SHARE` here.
