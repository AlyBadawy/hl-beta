# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Project Structure

```
hl-beta/
├── config/                      # Configuration (git-ignored secrets)
│   ├── secrets.example.yaml     # Example secrets structure (tracked)
│   └── secrets.yaml             # Actual secrets (git-ignored, created by provision.sh)
├── provision/                   # Provisioning automation
│   ├── provision.sh             # Main orchestration script (Phases 1-7)
│   ├── scripts/                 # Individual provisioning scripts
│   │   ├── config-secrets       # Phase 1: Configuration collection & validation
│   │   ├── check-ssh-connection # Phase 2: SSH connectivity verification
│   │   ├── update-dependencies  # Phase 3: System updates and package installation
│   │   ├── mount-nas            # Phase 4: NAS mount setup
│   │   ├── install-k3s          # Phase 5: K3s installation
│   │   ├── configure-cluster    # Phase 6: Cluster configuration provisioning
│   │   └── bootstrap-gitops     # Phase 7: Bootstrap GitOps (ArgoCD + root-app)
│   ├── lib/                     # Helper functions & utilities
│   │   ├── validation.sh        # Input validation functions
│   │   └── config.sh            # Configuration/secrets loading functions
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

### Phase 1: Configuration Collection ✓ Complete
**Script:** `provision/scripts/config-secrets`  
**Output:** `config/secrets.yaml`

Collects and validates infrastructure configuration interactively:
- Server IP and SSH credentials
- NAS storage location and mount path
- SMTP server configuration (server, port, username, password, from address)
- Admin and notification email addresses
- Base domain for the cluster

**Features:** Interactive prompts, input validation, sensible defaults, YAML output with restricted permissions (600).

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
- **URL:** http://argo.in.alybadawy.com (requires DNS: argo.in.alybadawy.com → 172.20.20.3)
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
See `docs/ADR-002-bootstrap-simplification.md`:
4. **Bootstrap Separation** — Two-phase approach:
   - Phase 7a: Deploy ArgoCD with minimal Helm values + Ingress via kubectl
   - Phase 7b: Root-app takes over configuration management via git
   - **Why:** Avoids Helm `valuesObject` JSON serialization issues with complex ingress configs

5. **Helm Values Format** — Use `helm.values` (YAML string) instead of `helm.valuesObject` (JSON)
   - **Why:** YAML format is more reliable for complex nested structures
   - **Lesson:** `valuesObject` can have JSON marshaling edge cases, prefer YAML strings

6. **Ingress Management** — Create Ingress as simple Kubernetes resource, not through Helm values
   - **Why:** Avoids configuration complexity, easier to troubleshoot
   - **Benefit:** Clean separation between bootstrap and GitOps layers

## Running the Provisioning

### Initial Setup
```bash
# Make scripts executable and run provisioning
./provision/provision.sh

# Result: Guided prompts create config/secrets.yaml
```

### Reviewing Configuration
```bash
cat config/secrets.yaml
```

### Updating Configuration
```bash
# Re-run and choose to reconfigure when prompted
./provision/provision.sh

# When prompted: Reconfigure secrets? [y/N]: 
# Type 'Y' to reconfigure all values
# Press Enter or 'N' to skip and keep existing configuration
```

On subsequent runs, the script will detect existing `config/secrets.yaml` and ask if you want to reconfigure. This allows for quick re-runs without redundant configuration prompts.

## Configuration Reference

See `config/secrets.example.yaml` for the structure. Key fields:

| Section | Field | Purpose | Default |
|---------|-------|---------|---------|
| server | ip | Target Ubuntu server IP | (required) |
| server | ssh_user | SSH user for remote access | homelab |
| nas | ip | NAS server IP | 172.20.20.2 |
| nas | base_share | NFS export path on NAS | /var/nfs/shared |
| nas | base_mount | Local mount point | /mnt/nas |
| smtp | server | Email server hostname | smtp.resend.com |
| smtp | port | SMTP port | 587 |
| smtp | username | SMTP auth username | (required) |
| smtp | password | SMTP auth password | (required) |
| smtp | from | Sender email address | (required) |
| email | admin | Admin notification email | (required) |
| domain | base | Base domain for cluster | in.alybadawy.com |

## Documentation

- **`provision/README.md`** — How to use the provisioning scripts
- **`docs/01-provisioning-architecture.md`** — Architecture and design philosophy
- **`docs/ADR-*.md`** — Architecture Decision Records with rationale

## Developer Notes

### When Adding New Configurations
1. Update the validation script (`provision/scripts/config-secrets`)
2. Add new fields to `config/secrets.example.yaml`
3. Document the field purpose and default in this CLAUDE.md
4. Update relevant ADR or create new one if it's a significant decision
5. Update `provision/README.md` if it changes how provisioning works

### Before Starting Phase 2
1. Review and confirm Phase 1 works as expected
2. Discuss Phase 2 scope with user
3. Create ADR-002 for Phase 2 decisions before implementation
4. Document Phase 2 architecture in `docs/02-server-bootstrap.md`

### Validation & Testing
Current approach:
- Input validation in the script (regex, ranges)
- Confirmation prompt before writing config
- No SSH/NAS connectivity checks yet (Phase 2 responsibility)

Future enhancements:
- Connection validation in Phase 2
- Dry-run mode for scripts
- Rollback capability

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
