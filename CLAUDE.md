# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Project Structure

```
hl-beta/
├── provision/                    # Provisioning automation
│   ├── provision-server.sh       # Server provisioning orchestrator (Phases 2-6)
│   ├── bootstrap-argocd.sh       # Phase 7: install ArgoCD
│   ├── restore-volumes.sh        # Phase 8: install Longhorn + restore PVC backups
│   ├── activate-gitops.sh        # Phase 9: apply app-of-apps, GitOps takes over
│   ├── scripts/                  # Individual provisioning scripts
│   │   ├── check-ssh-connection  # Phase 2: SSH connectivity verification
│   │   ├── update-dependencies   # Phase 3: System updates and package installation
│   │   ├── mount-nas             # Phase 4: NAS mount setup
│   │   ├── install-k3s           # Phase 5: K3s installation
│   │   └── configure-cluster     # Phase 6: Cluster configuration provisioning
│   ├── lib/                      # Helper functions & utilities
│   │   └── defaults.sh           # Hardcoded homelab defaults + require_server_ip helper
│   └── README.md                 # Provisioning documentation
├── k8s/
│   ├── apps/                     # ArgoCD Application manifests (app-of-apps)
│   │   ├── root.yaml             # Root app — watches k8s/apps/, self-managing
│   │   ├── argocd.yaml           # ArgoCD self-management Application
│   │   ├── longhorn.yaml         # Longhorn self-management Application
│   │   ├── ingress-nginx.yaml
│   │   ├── cert-manager.yaml
│   │   ├── external-secrets.yaml
│   │   ├── db.yaml
│   │   ├── vaultwarden.yaml
│   │   ├── monitor.yaml
│   │   └── whoami.yaml
│   └── components/               # Helm chart values + Kustomize overlays
│       ├── argocd/               # ArgoCD Helm values (bootstrapped + GitOps-managed)
│       ├── longhorn/             # Longhorn Helm values (bootstrapped + GitOps-managed)
│       ├── ingress-nginx/
│       ├── cert-manager/
│       ├── external-secrets/
│       ├── db/
│       ├── vaultwarden/
│       ├── monitor/
│       └── whoami/
├── docs/                         # Architecture and decision documentation
│   └── ADR-*.md                  # Architecture Decision Records with rationale
└── CLAUDE.md                     # This file

```

## Development Phases

Provisioning is executed as a sequence of phases, each running a shell script with one or more internal steps.

### Phase 2: SSH Connectivity Check ✓ Complete

**Script:** `provision/scripts/check-ssh-connection`

Validates SSH connectivity and NOPASSWD sudo access to target Ubuntu server:

- SSH key-based authentication working
- SSH user matches configured credentials
- Passwordless sudo (NOPASSWD) is configured

**Blocks provisioning if checks fail** — ensures server is ready before proceeding.

### Phase 3: System Updates & Dependencies ✓ Complete

**Script:** `provision/scripts/update-dependencies`

Prepares the Ubuntu server with essential packages and configuration:

- System package updates (`apt update` and `apt upgrade`)
- Installs essential packages (curl, wget, git, jq, vim, nfs-common, open-iscsi, apparmor, socat, etc.) — `open-iscsi` is required by Longhorn
- Disables SWAP (required for k3s)
- Displays system information (OS, kernel, CPU, memory, disk)

**Optional step** — user can skip with N when prompted (Y is default).

### Phase 4: NAS Storage Mounting ✓ Complete

**Script:** `provision/scripts/mount-nas`

Configures NFS mounts for persistent storage:

- Tests NAS connectivity
- Creates mount directories (`/mnt/nas/{homelab,backups,immich,nextcloud}`)
- Adds NFS entries to `/etc/fstab` with duplicate checking
- Mounts filesystems and verifies success
- Optimized NFS options for Kubernetes (automount, nofail, network timeout)

**Idempotent** — safe to re-run without duplication.

### Phase 5: K3s Cluster Installation ✓ Complete

**Script:** `provision/scripts/install-k3s`

Installs and validates a single-node k3s Kubernetes cluster:

- Checks if k3s is already installed (skips reinstall if present)
- Installs k3s v1.36.1+k3s1 with Traefik disabled
- Waits for k3s service to start (up to 1 minute with retries)
- Verifies cluster readiness (kubectl connectivity, node status, CoreDNS)
- Copies kubeconfig to local machine (`~/.kube/config`)
- Exports KUBECONFIG in shell profiles and current session

**Idempotent** — detects existing installation and skips reinstall.

### Phase 6: Cluster Configuration Provisioning ✓ Complete

**Script:** `provision/scripts/configure-cluster`

Provisions cluster-wide configuration from `config/secrets.yaml` as Kubernetes resources:

- Creates `cluster-config` namespace
- Creates `cluster-config` ConfigMap with non-sensitive data (domain, NAS paths, SMTP server, email, server IP)
- Creates `cluster-config` Secret with sensitive credentials (SMTP username and password)
- Verifies resources are created successfully

**Purpose:** Decouples configuration from application manifests, following 12-factor app principles. Applications can reference values via environment variables or volume mounts.

### Phase 7: Bootstrap ArgoCD ✓ Complete

**Script:** `provision/bootstrap-argocd.sh`

Installs ArgoCD onto the cluster and prepares the cert-manager secret. **Deliberately
stops before deploying any applications** — this gate allows Phase 8 to restore PVC
backups before stateful services start.

1. Installs ArgoCD via Kustomize + Helm from `k8s/components/argocd`
2. Waits for ArgoCD to be ready
3. Creates `cert-manager` namespace and `cloudflare-api-token` secret (DNS-01 challenge)

**Access ArgoCD before ingress is live:**
```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80
# open http://localhost:8080  username: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Phase 8: Longhorn + Volume Restore ✓ Complete

**Script:** `provision/restore-volumes.sh`

Installs Longhorn distributed storage and optionally restores PVC backups from NAS.

**Fresh cluster mode** (no backups to restore):
- Installs Longhorn via Kustomize + Helm from `k8s/components/longhorn`
- Configures NAS NFS share as the backup target
- Exits; volumes are created automatically on first use

**Cluster rebuild mode** (restoring from backup):
- Installs Longhorn, then port-forwards the Longhorn REST API
- Syncs the backup target and lists available backup volumes
- For each volume: restores from the latest backup, creates a pre-bound PV + PVC
- When Phase 9 deploys stateful apps, they bind to the restored PVCs

**Access Longhorn UI (once ingress-nginx and cert-manager are live):**
- https://longhorn.in.alybadawy.com
- Before ingress is live: `kubectl port-forward -n longhorn-system svc/longhorn-frontend 9000:80` → http://localhost:9000

### Phase 9: Activate GitOps ✓ Complete

**Script:** `provision/activate-gitops.sh`

Applies the root app-of-apps (`k8s/apps/root.yaml`) and hands full cluster ownership
to ArgoCD. After this, Git (main branch) is the sole source of truth.

- ArgoCD discovers all child apps in `k8s/apps/`
- Adopts the imperatively-installed ArgoCD and Longhorn with no diff (self-managing)
- Deploys ingress-nginx, cert-manager, external-secrets, and all application stacks
- Stateful apps bind to PVCs pre-created in Phase 8

**Access ArgoCD UI (once ingress-nginx syncs):**
- https://argo.in.alybadawy.com
- Username: `admin` — rotate the password on first login

## Key Design Decisions

See Architecture Decision Records in `docs/ADR-*.md` for detailed rationale.

### Provisioning Design

1. **Configuration Collection** — Interactive bash scripts with validation
2. **Security** — Secrets file (mode 600), never in git
3. **Modularity** — Each script has single responsibility

### GitOps Bootstrap Design

4. **Three-phase GitOps bootstrap** — Phases 7–9 are deliberately split so there is a
   safe window (Phase 8) to restore Longhorn PVC backups before stateful apps start.
   Without this, GitOps would create new empty volumes on first sync.

5. **Imperative bootstrap, GitOps adoption** — ArgoCD and Longhorn are installed
   imperatively (Kustomize + Helm) then adopted by `k8s/apps/argocd.yaml` and
   `k8s/apps/longhorn.yaml` respectively. The `k8s/components/*/` directories serve as
   both the bootstrap source and the GitOps source — ensuring zero diff on adoption.

6. **Pre-bound PVCs** — On a rebuild, PVCs are created with `spec.volumeName` pointing
   to a specific restored Longhorn volume. When apps deploy, they bind to existing PVCs
   instead of triggering dynamic provisioning. Namespace must exist before PVC creation.

## Running the Provisioning

### Initial Setup

```bash
# Server setup
./provision/provision-server.sh   # Phases 2–6

# GitOps bootstrap — run in order:
./provision/bootstrap-argocd.sh   # Phase 7: install ArgoCD
./provision/restore-volumes.sh    # Phase 8: install Longhorn + restore PVCs
./provision/activate-gitops.sh    # Phase 9: apply app-of-apps, GitOps takes over
```

Scripts prompt only for what varies at runtime. Everything else is hardcoded in `provision/lib/defaults.sh`.

## Configuration Reference

All static values live in `provision/lib/defaults.sh`. To override, export the variable before running:

```bash
export SMTP_FROM=alerts@mycompany.com
./provision/provision-server.sh
```

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
| `DOMAIN` | `in.alybadawy.com` | Base domain for cluster |
| `GIT_REPO` | `https://github.com/AlyBadawy/hl-beta` | GitOps repository URL |

**Prompted at runtime:** `SERVER_IP`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `CLOUDFLARE_API_TOKEN`.

## Documentation

- **`provision/README.md`** — How to use the provisioning scripts
- **`docs/01-provisioning-architecture.md`** — Architecture and design philosophy
- **`docs/ADR-*.md`** — Architecture Decision Records with rationale

## Developer Notes

### When Adding New Configurations

1. Add the variable with a sensible default to `provision/lib/defaults.sh`
2. Update the relevant sub-script to use the variable
3. Document the field in the Configuration Reference table above
4. Update `provision/README.md` if it changes how provisioning works
5. Create an ADR if it's a significant design decision

## Project Collaboration

**Important collaboration notes:**

- Discuss all architectural decisions before implementation
- Keep documentation updated with learnings and rationale
- Create ADRs when making significant design choices
- Explicitly ask questions when uncertain rather than assuming
- Document why decisions were made, not just how

---

**Last Updated:** 2026-06-04  
**Phase:** Phase 9 Complete — GitOps active
