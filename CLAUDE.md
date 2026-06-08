# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Project Structure

```
hl-beta/
├── provision/                    # Provisioning automation
│   ├── rebuild.sh                # Rebuild orchestrator (Steps 1–8)
│   ├── activate-gitops.sh        # Final step: apply app-of-apps, GitOps takes over
│   ├── scripts/                  # Individual step scripts
│   │   ├── check-ssh-connection  # Step 1: SSH connectivity verification
│   │   ├── update-dependencies   # Step 2: System updates and package installation
│   │   ├── mount-nas             # Step 3: NAS mount setup
│   │   ├── install-k3s           # Step 4: K3s installation
│   │   ├── configure-cluster     # Step 5: Cluster configuration provisioning
│   │   ├── bootstrap-argocd      # Step 7: install ArgoCD
│   │   └── restore-volumes       # Step 8: install Longhorn + restore PVC backups
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
│   │   ├── vault.yaml
│   │   ├── db.yaml
│   │   ├── monitor.yaml
│   │   └── whoami.yaml
│   └── components/               # Helm chart values + Kustomize overlays
│       ├── argocd/               # ArgoCD Helm values (bootstrapped + GitOps-managed)
│       ├── longhorn/             # Longhorn Helm values (bootstrapped + GitOps-managed)
│       ├── ingress-nginx/
│       ├── cert-manager/
│       ├── external-secrets/     # ClusterSecretStore — ESO reads from Vault
│       ├── vault/                # HashiCorp Vault — secrets backend (wave -1)
│       ├── db/
│       ├── monitor/
│       └── whoami/
├── docs/                         # Architecture and decision documentation
│   └── ADR-*.md                  # Architecture Decision Records with rationale
└── CLAUDE.md                     # This file

```

## Provisioning Steps

All steps are run by `provision/rebuild.sh`, which collects all interactive inputs upfront then executes each step in sequence. `activate-gitops.sh` is intentionally separate.

### Step 1: SSH Connectivity Check ✓ Complete

**Script:** `provision/scripts/check-ssh-connection`

Validates SSH connectivity and NOPASSWD sudo access to target Ubuntu server:

- SSH key-based authentication working
- SSH user matches configured credentials
- Passwordless sudo (NOPASSWD) is configured

**Blocks provisioning if checks fail** — ensures server is ready before proceeding.

### Step 2: System Updates & Dependencies ✓ Complete

**Script:** `provision/scripts/update-dependencies`

Prepares the Ubuntu server with essential packages and configuration:

- System package updates (`apt update` and `apt upgrade`)
- Installs essential packages (curl, wget, git, jq, vim, nfs-common, open-iscsi, apparmor, socat, etc.) — `open-iscsi` is required by Longhorn
- Disables SWAP (required for k3s)
- Displays system information (OS, kernel, CPU, memory, disk)

**Optional step** — user can skip with N when prompted (Y is default).

### Step 3: NAS Storage Mounting ✓ Complete

**Script:** `provision/scripts/mount-nas`

Configures NFS mounts for persistent storage:

- Tests NAS connectivity
- Creates mount directories (`/mnt/nas/{homelab,backups,immich,nextcloud}`)
- Adds NFS entries to `/etc/fstab` with duplicate checking
- Mounts filesystems and verifies success
- Optimized NFS options for Kubernetes (automount, nofail, network timeout)

**Idempotent** — safe to re-run without duplication.

### Step 4: K3s Cluster Installation ✓ Complete

**Script:** `provision/scripts/install-k3s`

Installs and validates a single-node k3s Kubernetes cluster:

- Checks if k3s is already installed (skips reinstall if present)
- Installs k3s v1.36.1+k3s1 with Traefik disabled
- Waits for k3s service to start (up to 1 minute with retries)
- Verifies cluster readiness (kubectl connectivity, node status, CoreDNS)
- Copies kubeconfig to local machine (`~/.kube/config`)
- Exports KUBECONFIG in shell profiles and current session

**Idempotent** — detects existing installation and skips reinstall.

### Step 5: Cluster Configuration Provisioning ✓ Complete

**Script:** `provision/scripts/configure-cluster`

Provisions cluster-wide configuration from `config/secrets.yaml` as Kubernetes resources:

- Creates `cluster-config` namespace
- Creates `cluster-config` ConfigMap with non-sensitive data (domain, NAS paths, admin email, server IP)
- Applies kernel tuning (`inotify`, `vm.max_map_count`)
- Verifies resources are created successfully

**Purpose:** Decouples configuration from application manifests, following 12-factor app principles. Applications can reference values via environment variables or volume mounts.

### Step 6: Seed Vault Unseal Key ✓ Complete

Handled inline by `provision/rebuild.sh` — creates the `security` namespace and seeds
the `vault-unseal-key` secret before ArgoCD starts. Without it, Vault stays sealed,
ESO cannot sync, and all apps fail to start.

### Step 7: Bootstrap ArgoCD ✓ Complete

**Script:** `provision/scripts/bootstrap-argocd`

Installs ArgoCD onto the cluster and prepares the cert-manager secret. **Deliberately
stops before deploying any applications** — this gate allows Step 8 to restore PVC
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

### Step 8: Longhorn + Volume Restore ✓ Complete

**Script:** `provision/scripts/restore-volumes`

Installs Longhorn distributed storage and optionally restores PVC backups from NAS.

**Fresh cluster mode** (no backups to restore):
- Installs Longhorn via Kustomize + Helm from `k8s/components/longhorn`
- Configures NAS NFS share as the backup target
- Exits; volumes are created automatically on first use

**Cluster rebuild mode** (restoring from backup):
- Installs Longhorn, then opens the Longhorn UI via port-forward on `localhost:9000`
- Operator manually restores each volume from the UI (Backup → Restore) and creates PV/PVCs
- Script waits for operator confirmation, then exits
- When `activate-gitops.sh` deploys stateful apps, they bind to the restored PVCs

**Access Longhorn UI (once ingress-nginx and cert-manager are live):**
- https://longhorn.in.alybadawy.com
- Before ingress is live: `kubectl port-forward -n longhorn-system svc/longhorn-frontend 9000:80` → http://localhost:9000

### Final Step: Activate GitOps ✓ Complete

**Script:** `provision/activate-gitops.sh`

Applies the root app-of-apps (`k8s/apps/root.yaml`) and hands full cluster ownership
to ArgoCD. After this, Git (main branch) is the sole source of truth.

- ArgoCD discovers all child apps in `k8s/apps/`
- Adopts the imperatively-installed ArgoCD and Longhorn with no diff (self-managing)
- Deploys ingress-nginx, cert-manager, external-secrets, vault, and all application stacks
- Vault (sync-wave `-1`) starts first; the auto-unseal CronJob unseals it (typically 5–6 min after boot — Longhorn PVC reattachment is the bottleneck)
- Once Vault is unsealed, the eso-recovery CronJob detects the degraded ClusterSecretStore and restarts ESO; ESO reconnects and syncs all ExternalSecrets
- Apps start with their secrets populated — full post-boot recovery is automatic with no manual steps
- Stateful apps bind to PVCs pre-created in Step 8

**Access ArgoCD UI (once ingress-nginx syncs):**
- https://argo.in.alybadawy.com
- Username: `admin` — rotate the password on first login

**Access Vault UI:**
- https://vault.in.alybadawy.com
- Before ingress is live: `kubectl port-forward -n security svc/vault 8200:8200` → http://localhost:8200

## Key Design Decisions

See Architecture Decision Records in `docs/ADR-*.md` for detailed rationale.

### Provisioning Design

1. **Configuration Collection** — Interactive bash scripts with validation
2. **Security** — Secrets file (mode 600), never in git
3. **Modularity** — Each script has single responsibility

### GitOps Bootstrap Design

4. **Staged bootstrap with a restore gate** — Steps 7–8 are deliberately separated from
   `activate-gitops.sh` so there is a safe window to restore Longhorn PVC backups before
   stateful apps start. Without this, GitOps would create new empty volumes on first sync.

5. **Imperative bootstrap, GitOps adoption** — ArgoCD and Longhorn are installed
   imperatively (Kustomize + Helm) then adopted by `k8s/apps/argocd.yaml` and
   `k8s/apps/longhorn.yaml` respectively. The `k8s/components/*/` directories serve as
   both the bootstrap source and the GitOps source — ensuring zero diff on adoption.

6. **Pre-bound PVCs** — On a rebuild, PVCs are created with `spec.volumeName` pointing
   to a specific restored Longhorn volume. When apps deploy, they bind to existing PVCs
   instead of triggering dynamic provisioning. Namespace must exist before PVC creation.

### Secrets Design

7. **HashiCorp Vault as the ESO secrets backend** — All application secrets are stored in
   Vault KV v2 under `secret/`. ESO reads from Vault via the `ClusterSecretStore/k8s-secrets`
   (Vault provider, Kubernetes auth). No secrets are stored in git or in a `secrets` namespace.
   Vault runs in the `security` namespace as a StatefulSet backed by a Longhorn PVC.

8. **Auto-unseal CronJob** — `vault-auto-unseal` runs every minute in the `security` namespace.
   It checks Vault's TCP port with `nc`, then runs `timeout 5 vault status` (plain `vault status`
   hangs at the HTTP layer while Longhorn reattaches storage — the timeout kills it and retries
   next minute). Exit code 2 = sealed → unseal; 0 = already unsealed; anything else = not ready,
   retry. The unseal key is stored in the `vault-unseal-key` Secret in the `security` namespace.

9. **ESO recovery CronJob** — `eso-recovery` runs every minute alongside the unseal CronJob.
   It checks if `vault-0` is ready (Vault's readiness probe fails when sealed, so `ready=true`
   means unsealed) and if the `k8s-secrets` ClusterSecretStore is degraded. When Vault comes
   back but ESO is still in exponential backoff, the job restarts the three ESO deployments in
   the `security` namespace to clear the backoff and force reconnection. During normal operation
   (store already Ready) it exits immediately — cheap to run every minute.

10. **Full post-reboot recovery is automatic** — After a reboot the sequence is:
    1. Vault pod starts sealed; ESO enters backoff (store degraded)
    2. `vault-auto-unseal` retries every minute; Longhorn reattaches the PVC (~4–5 min)
    3. Vault unseals; `vault-0` becomes Ready
    4. `eso-recovery` detects Vault ready + store degraded → restarts ESO
    5. ESO reconnects to Vault; all ExternalSecrets sync; apps recover
    Total time from boot to fully healthy: ~6 minutes. No manual intervention required.

11. **Rebuild requires only one manual secret** — After restoring Longhorn backups (which
    include Vault's data PVC), only `vault-unseal-key` needs to be seeded before GitOps runs.
    Everything else flows automatically: Vault unseals → ESO syncs → apps start.

## Running the Provisioning

### Initial Setup

```bash
# Steps 1–8: provision server, seed secrets, bootstrap ArgoCD, install Longhorn
./provision/rebuild.sh

# Final step: apply app-of-apps, GitOps takes over
./provision/activate-gitops.sh    # → Vault starts (wave -1), CronJob unseals it
                                  # → ESO syncs all secrets from Vault → apps start
```

`rebuild.sh` prompts for server IP, Vault unseal key, and Cloudflare token upfront then runs unattended through Step 7. Step 8 requires manual Longhorn UI interaction for volume restore. Everything else is hardcoded in `provision/lib/defaults.sh`.

## Configuration Reference

All static values live in `provision/lib/defaults.sh`. To override, export the variable before running:

```bash
export ADMIN_EMAIL=alerts@mycompany.com
./provision/rebuild.sh
```

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | `homelab` | SSH user on the target server |
| `NAS_IP` | `172.20.20.2` | NAS server IP |
| `NAS_BASE_SHARE` | `/var/nfs/shared` | NFS export path on NAS |
| `NAS_BASE_MOUNT` | `/mnt/nas` | Local mount point |
| `ADMIN_EMAIL` | `alybadawy@icloud.com` | Admin notification email |
| `DOMAIN` | `in.alybadawy.com` | Base domain for cluster |
| `GIT_REPO` | `https://github.com/AlyBadawy/hl-beta` | GitOps repository URL |

**Prompted at runtime:** `SERVER_IP`, `VAULT_UNSEAL_KEY`, `CLOUDFLARE_API_TOKEN`.

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

**Last Updated:** 2026-06-07  
**Status:** All steps complete — GitOps active, fully automatic post-reboot recovery
