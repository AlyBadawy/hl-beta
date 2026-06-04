# Provisioning

Automated provisioning scripts for k3s cluster setup.

## Quick Start

```bash
./provision/provision-server.sh   # Phases 2–6: server setup
./provision/provision-gitops.sh   # Phase 7: GitOps bootstrap
```

Both scripts prompt for the only values that vary at runtime — everything else is hardcoded in `provision/lib/defaults.sh`.

## Configuration

All static values live in [`lib/defaults.sh`](lib/defaults.sh) and can be overridden by exporting an environment variable before running:

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | `homelab` | SSH user on the target server |
| `NAS_IP` | `172.20.20.2` | NAS server IP |
| `NAS_BASE_SHARE` | `/var/nfs/shared` | NFS export path on NAS |
| `NAS_BASE_MOUNT` | `/mnt/nas` | Local mount point |
| `SMTP_SERVER` | `smtp.resend.com` | SMTP server hostname |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_FROM` | `noreply@alybadawy.com` | Sender email address |
| `ADMIN_EMAIL` | `alybadawy@icloud.com` | Admin notification email |
| `DOMAIN` | `in.alybadawy.com` | Base domain for the cluster |
| `GIT_REPO` | `https://github.com/AlyBadawy/hl-beta` | GitOps repository URL |

**Prompted at runtime:**
- `SERVER_IP` — prompted once at the top of `provision-server.sh`
- `SMTP_USERNAME` / `SMTP_PASSWORD` — prompted by `configure-cluster` (Phase 6)
- `GIT_REPO` (overridable) — shown with default, prompted by `provision-gitops.sh`
- `VERCEL_API_TOKEN` — prompted by `provision-gitops.sh`

## Provisioning Phases

### Phase 2: `check-ssh-connection`

Validates SSH connectivity and NOPASSWD sudo access to the target server.

### Phase 3: `update-dependencies`

Updates packages and installs essentials (curl, wget, git, jq, nfs-common, apparmor, socat, etc.), disables SWAP, and installs Helm.

### Phase 4: `mount-nas`

Configures NFS mounts for `/mnt/nas/{homelab,backups,immich,nextcloud}` via `/etc/fstab`. Idempotent — safe to re-run.

### Phase 5: `install-k3s`

Installs k3s `v1.36.1+k3s1` with Traefik disabled, waits for readiness, and copies kubeconfig locally to `~/.kube/config`.

### Phase 6: `configure-cluster`

Creates a `cluster-config` namespace, ConfigMap (non-sensitive values), and Secret (SMTP credentials) in the cluster. Applications reference these via `configMapKeyRef` / `secretKeyRef`.

### Phase 7: `provision-gitops.sh`

Installs nginx-ingress and ArgoCD via Helm, then hands ownership to a GitOps root-app Application pointing at this repo.

## Helper Library

### `lib/defaults.sh`

Defines all hardcoded homelab values and the `require_server_ip` helper function. All sub-scripts source this file.
