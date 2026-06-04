# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Project Structure

```
hl-beta/
├── provision/                   # Provisioning automation
│   ├── provision-server.sh      # Server provisioning orchestrator (Phases 2-6)
│   ├── provision-gitops.sh      # GitOps bootstrap (Phase 7)
│   ├── scripts/                 # Individual provisioning scripts
│   │   ├── check-ssh-connection # Phase 2: SSH connectivity verification
│   │   ├── update-dependencies  # Phase 3: System updates and package installation
│   │   ├── mount-nas            # Phase 4: NAS mount setup
│   │   ├── install-k3s          # Phase 5: K3s installation
│   │   └── configure-cluster    # Phase 6: Cluster configuration provisioning
│   ├── lib/                     # Helper functions & utilities
│   │   └── defaults.sh          # Hardcoded homelab defaults + require_server_ip helper
│   └── README.md                # Provisioning documentation
├── git-ops/                     # GitOps - App of Apps configuration
│   ├── root-app/                # Root Application (Helm chart)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── argocd-app.yaml         # ArgoCD Application (self-managing)
│   │       ├── nginx-ingress-app.yaml  # Nginx Ingress Application
│   │       └── git-config-cm.yaml      # Git repository configuration
│   ├── argocd/                  # ArgoCD Helm values
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── nginx-ingress/           # Nginx-ingress Helm values
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   └── README.md                # GitOps documentation
├── docs/                        # Architecture and decision documentation
│   ├── 01-provisioning-architecture.md  # Phase 1 architecture overview
│   └── ADR-001-provisioning-script-design.md  # Design decisions & rationale
└── CLAUDE.md                    # This file

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
- Installs 23 essential packages (curl, wget, git, jq, vim, nfs-common, apparmor, socat, etc.)
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

### Phase 7: Bootstrap GitOps ✓ Complete

**Script:** `provision/scripts/bootstrap-gitops`

Initializes GitOps infrastructure with ArgoCD and App of Apps pattern using a two-phase approach:

**Phase 7a - Bootstrap:**

1. Installs nginx-ingress controller via Helm (prerequisite for ingress routing)
2. Creates ArgoCD namespace
3. Installs ArgoCD via Helm with **simplified bootstrap values** (no complex ingress config)
4. Creates Ingress resource via kubectl (separate from Helm values)
5. Creates bootstrap Application pointing to git-ops/root-app
6. Waits for ArgoCD to be ready
7. Retrieves admin credentials

**Phase 7b - GitOps Takeover:**

1. Root-app Application syncs from git and orchestrates cluster
2. Root-app deploys argocd-app.yaml (ArgoCD self-manages itself)
3. Root-app deploys nginx-ingress-app.yaml (Ingress controller)
4. Git (main branch) becomes source of truth for all configurations

**Key Design: Bootstrap Separation**

- Bootstrap uses minimal, simple Helm values to avoid Helm ingress configuration complexity
- Ingress created as simple Kubernetes resource via kubectl
- Root-app takes over full configuration management after bootstrap
- See `docs/ADR-002-bootstrap-simplification.md` for rationale

**Access ArgoCD:**

- **URL:** http://argo.in.alybadawy.com
- **Port Forward:** `kubectl port-forward -n argocd svc/argocd-server 8080:80` then http://localhost:8080
- **Username:** admin
- **Password:** `kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- **Action:** Change password on first login

### Phase 8: Application Deployment (Planned)

**Scripts:** (TBD)

Deploy additional applications and services:

- Longhorn for distributed storage
- Vaultwarden for secrets management
- Custom applications and services
- DNS, monitoring, and logging infrastructure

## Key Design Decisions

See Architecture Decision Records in `docs/ADR-*.md` for detailed rationale.

### Phase 1-6 Decisions

See `docs/ADR-001-provisioning-script-design.md`:

1. **Configuration Collection** — Interactive bash scripts with validation
2. **Security** — Secrets file (mode 600), never in git
3. **Modularity** — Each script has single responsibility

### Phase 7 Decisions

See `docs/ADR-002-bootstrap-simplification.md` and `docs/ADR-003-gitops-ownership-and-ingress.md`:

4. **Bootstrap Separation** — Bootstrap installs nginx-ingress + ArgoCD minimally via Helm, then hands off to GitOps.

5. **Helm Tracking Secret Deletion** — After each `helm install` in bootstrap, the Helm release tracking Secret is deleted so ArgoCD becomes the sole owner. Running resources are preserved. (ADR-003)

6. **Multi-source ArgoCD Applications** — `nginx-ingress-app.yaml` and `argocd-app.yaml` use ArgoCD multi-source: upstream Helm chart + `$values` ref pointing to this repo's values files. This makes `git-ops/*/values.yaml` the single source of truth for both bootstrap and GitOps. (ADR-003)

7. **ArgoCD Ingress as root-app manifest** — The ArgoCD Ingress (`argocd-server-ingress`) is a plain Kubernetes manifest in `root-app/templates/argocd-ingress.yaml`, templated with `{{ .Values.domain }}`. Bootstrap does NOT create this ingress manually. It appears when root-app first syncs. (ADR-003)

## Running the Provisioning

### Initial Setup

```bash
./provision/provision-server.sh   # Phases 2–6
./provision/provision-gitops.sh   # Phase 7
```

Both scripts prompt only for what varies at runtime (server IP, SMTP credentials, Vercel token). Everything else is hardcoded in `provision/lib/defaults.sh`.

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

**Prompted at runtime:** `SERVER_IP`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `VERCEL_API_TOKEN`.

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

**Last Updated:** 2026-05-29  
**Phase:** Configuration Management (Phase 1)
