# Cluster Rebuild Guide

Step-by-step instructions for rebuilding the entire cluster on a new node and restoring all data from backups. Follow these phases in order — skipping or reordering them will cause dependency failures.

**Last Updated:** 2026-06-06  
**Applies to:** k3s v1.36.1, ArgoCD on main branch, single-node cluster

---

## Before You Start

### What is automatically restored

| Data | Backup mechanism | Restored in phase |
|---|---|---|
| Vaultwarden vault data | Longhorn PVC backup → NAS | Phase 5 |
| PostgreSQL databases (authentik, immich, nextcloud) | Daily `pg_dump` → NAS (`/mnt/nas/backups/postgres`) | Phase 7 (manual) |
| Longhorn volumes (all `-lh` PVCs) | Longhorn backup every 6h → NAS | Phase 5 |
| Immich photos | NAS (`/mnt/nas/immich`) — live, not backed up separately | Available immediately after NAS mounts |
| Nextcloud files | NAS (`/mnt/nas/nextcloud`) — live, not backed up separately | Available immediately after NAS mounts |
| Grafana dashboards | `local-path` PVC — NOT backed up by Longhorn | Must be re-imported manually |
| Prometheus metrics history | `local-path` PVC — NOT backed up | Lost on rebuild (expected) |

### What requires manual intervention

These values are never stored in git and must be supplied from your offline backup / password manager before the cluster can sync:

| Credential | Where it's needed |
|---|---|
| New node IP address | All provisioning scripts |
| SSH private key for `homelab` user | Your local `~/.ssh/` |
| Cloudflare API token (Zone:DNS:Edit) | `bootstrap-argocd.sh` prompt |
| SMTP username + password | `provision-server.sh` prompt (Phase 6) |
| Vaultwarden master password | Unlocking vault after restore |
| All secrets listed in the [Secrets Seeding](#phase-4-seed-secrets) section | Before GitOps activates |

### Required tools on your local machine

```bash
# Verify these are installed before starting
kubectl version --client
kustomize version
helm version
jq --version
bw --version    # Bitwarden CLI — brew install bitwarden-cli
```

---

## Phase 1: Prepare the New Node

Perform these steps on the **new server** before running any provisioning scripts.

### 1.1 Install Ubuntu 24.04 LTS (or 26.04)

Fresh install. No desktop environment needed. Minimum specs:
- 4 vCPU, 8 GB RAM
- 100 GB disk (SSD preferred)
- Static IP or DHCP reservation — record the IP

### 1.2 Create the `homelab` user

```bash
# On the new server as root:
adduser homelab
usermod -aG sudo homelab

# Configure passwordless sudo
echo "homelab ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/homelab
chmod 0440 /etc/sudoers.d/homelab
```

### 1.3 Install your SSH public key

```bash
# From your local machine:
ssh-copy-id homelab@<NEW_SERVER_IP>

# Verify:
ssh homelab@<NEW_SERVER_IP> 'sudo whoami'
# Should print: root
```

### 1.4 Verify NAS reachability from the new node

```bash
ssh homelab@<NEW_SERVER_IP> "ping -c 3 172.20.20.2"
```

If the NAS is unreachable, do not proceed — Phase 4 (NAS mounts) will fail, and Immich/Nextcloud data will not be accessible.

---

## Phase 2: Server Provisioning (Phases 2–6)

From your **local machine**, in the repo root:

```bash
cd ~/hl-beta
./provision/provision-server.sh
```

When prompted:
- **Server IP:** enter the new node's IP
- **SMTP username:** your Resend (or other SMTP) username
- **SMTP password:** your SMTP password

This runs through five internal phases:

| Phase | Script | What it does |
|---|---|---|
| 2 | `check-ssh-connection` | Validates SSH + NOPASSWD sudo |
| 3 | `update-dependencies` | `apt upgrade`, installs packages incl. `open-iscsi`, disables swap |
| 4 | `mount-nas` | Creates `/mnt/nas/{homelab,backups,immich,nextcloud}`, adds NFS fstab entries |
| 5 | `install-k3s` | Installs k3s v1.36.1 (Traefik disabled), copies kubeconfig to `~/.kube/config` |
| 6 | `configure-cluster` | Creates `cluster-config` namespace, ConfigMap, Secret, applies kernel tuning |

When complete, verify:

```bash
kubectl get nodes
# Expected: node in Ready state

kubectl get configmap cluster-config -n cluster-config
# Expected: configmap with domain, NAS paths, SMTP config
```

---

## Phase 3: Create the `secrets` Namespace

The `secrets` namespace is the internal source of truth that ESO reads from. It must exist and be populated **before** ArgoCD deploys any application — otherwise ExternalSecrets will fail to sync and apps will not start.

```bash
kubectl create namespace secrets
```

---

## Phase 4: Seed Secrets

All secrets below go into the `secrets` namespace. ESO reads them and distributes copies into application namespaces automatically.

**How to apply each secret** — the pattern used throughout this section:

```bash
kubectl create secret generic <name> \
  --namespace=secrets \
  --from-literal=<KEY>="<value>" \
  [--from-literal=<KEY2>="<value2>" ...] \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

Using `--dry-run=client -o yaml | kubectl apply -f -` makes each command idempotent and safe to re-run.

---

### 4.1 Vaultwarden admin token

This must be seeded **first**. The Vaultwarden app will not start without it.

If you have the previous `ADMIN_TOKEN` from your offline backup, use it. If not, generate a new one (you will need to use this token to log into Vaultwarden's `/admin` panel after restore).

```bash
# Option A: Use your saved token
ADMIN_TOKEN="<your-saved-admin-token>"

# Option B: Generate a new one (save it before running)
ADMIN_TOKEN="$(openssl rand -base64 48)"
echo "SAVE THIS: $ADMIN_TOKEN"

kubectl create secret generic vaultwarden-admin \
  --namespace=secrets \
  --from-literal=ADMIN_TOKEN="$ADMIN_TOKEN" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

> Save the `ADMIN_TOKEN` to your local password manager before continuing.

---

### 4.2 Unlock Vaultwarden (if restoring from backup)

If the Vaultwarden Longhorn PVC backup contains your existing vault data, you can log in with your master password after Phase 6 completes. Use the bw CLI to pull remaining secrets from Vaultwarden and seed them into the cluster.

If Vaultwarden is unavailable (first-ever build, or vault data lost), seed all secrets manually using the commands in sections 4.3–4.11 with values from your offline backup.

```bash
# Configure bw CLI to point at your instance
bw config server https://vault.in.alybadawy.com

# Login and unlock (run after Phase 6 if Vaultwarden is already running)
bw login
export BW_SESSION=$(bw unlock --raw)
```

---

### 4.3 PostgreSQL master credentials

```bash
# From Vaultwarden:
ITEM=$(bw get item 'postgres-secret' --session $BW_SESSION)
kubectl create secret generic postgres-secret \
  --namespace=secrets \
  --from-literal=POSTGRES_USER="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=POSTGRES_PASSWORD="$(echo "$ITEM" | jq -r '.login.password')" \
  --from-literal=POSTGRES_DB="$(echo "$ITEM" | jq -r '.fields[] | select(.name=="POSTGRES_DB") | .value')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

# Or manually:
kubectl create secret generic postgres-secret \
  --namespace=secrets \
  --from-literal=POSTGRES_USER="postgres" \
  --from-literal=POSTGRES_PASSWORD="<your-postgres-password>" \
  --from-literal=POSTGRES_DB="postgres" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.4 Authentik database credentials

```bash
# From Vaultwarden:
ITEM=$(bw get item 'authentik-db' --session $BW_SESSION)
kubectl create secret generic authentik-db \
  --namespace=secrets \
  --from-literal=username="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=password="$(echo "$ITEM" | jq -r '.login.password')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.5 Authentik secret key

This is a cryptographic key that signs Authentik sessions. If you use a different value than the original, all sessions are invalidated (users must log in again) but no data is lost.

```bash
# From Vaultwarden:
ITEM=$(bw get item 'authentik-secret' --session $BW_SESSION)
kubectl create secret generic authentik-secret \
  --namespace=secrets \
  --from-literal=secret_key="$(echo "$ITEM" | jq -r '.notes')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

# Or generate a new one (sessions will be invalidated, data is safe):
kubectl create secret generic authentik-secret \
  --namespace=secrets \
  --from-literal=secret_key="$(openssl rand -hex 50)" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.6 Immich database credentials

```bash
ITEM=$(bw get item 'immich-db' --session $BW_SESSION)
kubectl create secret generic immich-db \
  --namespace=secrets \
  --from-literal=username="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=password="$(echo "$ITEM" | jq -r '.login.password')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.7 Nextcloud database credentials

```bash
ITEM=$(bw get item 'nextcloud-db' --session $BW_SESSION)
kubectl create secret generic nextcloud-db \
  --namespace=secrets \
  --from-literal=username="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=password="$(echo "$ITEM" | jq -r '.login.password')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.8 pgAdmin credentials

```bash
ITEM=$(bw get item 'pgadmin-secret' --session $BW_SESSION)
kubectl create secret generic pgadmin-secret \
  --namespace=secrets \
  --from-literal=PGADMIN_DEFAULT_EMAIL="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=PGADMIN_DEFAULT_PASSWORD="$(echo "$ITEM" | jq -r '.login.password')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.9 SMTP credentials (Resend)

```bash
ITEM=$(bw get item 'resend-smtp' --session $BW_SESSION)
kubectl create secret generic resend-smtp \
  --namespace=secrets \
  --from-literal=host="$(echo "$ITEM" | jq -r '.fields[] | select(.name=="host") | .value')" \
  --from-literal=port="$(echo "$ITEM" | jq -r '.fields[] | select(.name=="port") | .value')" \
  --from-literal=username="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=password="$(echo "$ITEM" | jq -r '.login.password')" \
  --from-literal=from_address="$(echo "$ITEM" | jq -r '.fields[] | select(.name=="from_address") | .value')" \
  --from-literal=use_tls="$(echo "$ITEM" | jq -r '.fields[] | select(.name=="use_tls") | .value')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.10 Grafana admin credentials

```bash
ITEM=$(bw get item 'grafana-admin' --session $BW_SESSION)
kubectl create secret generic grafana-admin \
  --namespace=secrets \
  --from-literal=admin-user="$(echo "$ITEM" | jq -r '.login.username')" \
  --from-literal=admin-password="$(echo "$ITEM" | jq -r '.login.password')" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
```

---

### 4.11 Verify all secrets are present

```bash
kubectl get secrets -n secrets
```

Expected output — confirm all of these exist:

```
vaultwarden-admin
postgres-secret
authentik-db
authentik-secret
immich-db
nextcloud-db
pgadmin-secret
resend-smtp
grafana-admin
```

If any are missing, seed them before proceeding.

---

## Phase 5: Bootstrap ArgoCD

```bash
./provision/bootstrap-argocd.sh
```

When prompted:
- **Cloudflare API token:** paste your token (Zone → DNS → Edit for `alybadawy.com`)

This script:
1. Installs ArgoCD from `k8s/components/argocd` via Kustomize + Helm
2. Waits for `argocd-server` and `argocd-repo-server` to be ready
3. Creates the `networking` namespace and seeds the `cloudflare-api-token` secret

Verify ArgoCD is up:

```bash
kubectl get pods -n argocd
# All pods should be Running/Ready

# Get the initial admin password (rotate this after first login)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Access the UI before ingress is live
kubectl port-forward -n argocd svc/argocd-server 8080:80
# open http://localhost:8080
```

---

## Phase 6: Install Longhorn and Restore Volumes

```bash
./provision/restore-volumes.sh
```

The script will ask:

> **Is this a fresh cluster with no backups to restore? [y/N]**

- Answer **`n`** (default) to restore from NAS backups — this is what you want for a rebuild.
- Answer **`y`** only on a first-ever install with no existing data.

### What happens in restore mode

1. Installs Longhorn from `k8s/components/longhorn`
2. Port-forwards the Longhorn API on `localhost:9000`
3. Syncs the backup target (`nfs://172.20.20.2:/var/nfs/shared/backups/pvcs`)
4. Lists all available backup volumes on the NAS
5. For each volume, prompts for the target namespace and PVC name
6. Creates a Longhorn volume from the latest backup, then creates a pre-bound PV + PVC

### Prompted values for each backup volume

The script will show you each available volume name and ask:

```
Namespace for "<volume>": <answer>
PVC name for "<volume>": <answer>
```

Use these answers (must match the PVC names in the manifests exactly):

| Backup volume name (from NAS) | Namespace | PVC name |
|---|---|---|
| `vaultwarden-data-lh` | `security` | `vaultwarden-data-lh` |
| `postgres-data-lh` | `db` | `postgres-data-lh` |
| `nextcloud-data-lh` | `cloud` | `nextcloud-data-lh` |
| `authentik-media-lh` | `security` | `authentik-media-lh` |
| `authentik-templates-lh` | `security` | `authentik-templates-lh` |

> If a backup volume name in the NAS does not match the table above (e.g., due to a rename), check the actual PVC names in the manifests: `grep -r "claimName" k8s/components/ --include="*.yaml"`.

After the restore completes, verify the PVCs exist:

```bash
kubectl get pvc -A | grep -E "lh$"
```

All `-lh` PVCs should show `Bound` status.

---

## Phase 7: Activate GitOps

```bash
./provision/activate-gitops.sh
```

This applies `k8s/apps/root.yaml` and hands full cluster ownership to ArgoCD. After this, every application in `k8s/apps/` begins syncing from `main`.

Watch the rollout:

```bash
# Watch all ArgoCD applications sync
kubectl get applications -n argocd -w

# Or use the ArgoCD UI
kubectl port-forward -n argocd svc/argocd-server 8080:80
# open http://localhost:8080
```

**Expected sync order** (ArgoCD respects sync-wave annotations):

1. `external-secrets` — ESO operator deploys; ClusterSecretStore becomes Ready
2. `cert-manager` — cert-manager deploys; ClusterIssuers created
3. `ingress-nginx` — nginx controller gets an IP; TLS challenges can now complete
4. `db` — PostgreSQL and Redis deploy with restored PVCs
5. `auth` — Authentik deploys with restored media PVC
6. `vaultwarden` — Vaultwarden deploys with restored data PVC
7. `cloud` — Nextcloud deploys with restored config PVC
8. `immich` — Immich deploys; photos are immediately available from NAS
9. `monitor` — Prometheus + Grafana deploy
10. `aly`, `whoami` — static sites deploy

Allow 10–15 minutes for all apps to reach `Synced / Healthy`.

---

## Phase 8: Restore PostgreSQL Databases

Longhorn restores the PostgreSQL *data volume*, which should contain all databases intact. However, if the Longhorn backup was taken when PostgreSQL was mid-write (unlikely with the daily pg_dump schedule, but possible), you may need to fall back to the pg_dump backups.

### 8.1 Verify databases are intact

```bash
kubectl exec -n db deploy/postgres -- \
  psql -U postgres -c '\l'
```

Expected: `authentik`, `immich`, `nextcloud` all listed.

Spot-check row counts:

```bash
# Immich — confirm photos are tracked
kubectl exec -n db deploy/postgres -- \
  psql -U postgres -d immich -c 'SELECT COUNT(*) FROM assets;'

# Authentik — confirm users exist
kubectl exec -n db deploy/postgres -- \
  psql -U postgres -d authentik -c 'SELECT COUNT(*) FROM authentik_core_user;'
```

### 8.2 Restore from pg_dump (if Longhorn restore was incomplete)

pg_dump backups are on the NAS at `/mnt/nas/backups/postgres/` and are already mounted at that path on the new node.

```bash
# Find the latest dump files (format: <db>-YYYYMMDD-HHMM.dump)
ls -lt /mnt/nas/backups/postgres/ | head -20

# Restore a specific database (replace filename with actual latest)
DUMP_FILE="/mnt/nas/backups/postgres/immich-20260606-0200.dump"

kubectl exec -i -n db deploy/postgres -- \
  pg_restore -U postgres -d immich --clean --if-exists < "$DUMP_FILE"

# Repeat for authentik and nextcloud
```

---

## Phase 9: Post-Rebuild Verification

### 9.1 Certificates

TLS certificates are issued automatically by cert-manager once ingress-nginx is running and DNS is resolving. Allow up to 5 minutes after ingress-nginx syncs.

```bash
kubectl get certificates -A
# All should show READY=True
```

If a certificate stays `False`:

```bash
kubectl describe certificate <name> -n <namespace>
kubectl describe certificaterequest -n <namespace>
# Look for DNS-01 challenge errors — usually a Cloudflare token issue
```

### 9.2 DNS

Confirm the cluster's external IP and update DNS if the new node has a different IP:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# Note the EXTERNAL-IP
```

If the IP changed, update the wildcard A record for `*.in.alybadawy.com` in Cloudflare to point at the new IP.

### 9.3 Service health checks

```bash
# Check all pods are Running
kubectl get pods -A | grep -v Running | grep -v Completed

# Check ArgoCD sees everything as Synced/Healthy
kubectl get applications -n argocd

# Check ESO synced all ExternalSecrets
kubectl get externalsecrets -A
# All should show READY=True and STATUS=SecretSynced
```

### 9.4 Application smoke tests

| Service | URL | What to check |
|---|---|---|
| ArgoCD | `https://argo.in.alybadawy.com` | Login with admin; all apps green |
| Vaultwarden | `https://vault.in.alybadawy.com` | Login with master password; vault items present |
| Authentik | `https://auth.in.alybadawy.com` | Login; users and flows intact |
| Immich | `https://immich.in.alybadawy.com` | Login; photos visible |
| Nextcloud | `https://cloud.in.alybadawy.com` | Login; files accessible |
| Longhorn | `https://longhorn.in.alybadawy.com` | All volumes healthy; backup target connected |
| Grafana | `https://grafana.in.alybadawy.com` | Login; dashboards load |

### 9.5 Restore Grafana dashboards

Grafana uses a `local-path` PVC which is **not** backed up by Longhorn. Dashboards must be re-imported.

```bash
# Port-forward if ingress isn't up yet
kubectl port-forward -n monitor svc/monitor-grafana 3000:80

# Then import dashboards from grafana.com using their IDs, or from JSON exports
# if you exported them before the rebuild.
```

Recommended dashboards to re-import from grafana.com:

| Dashboard | ID |
|---|---|
| Kubernetes cluster overview | 7249 |
| Longhorn | 16888 |
| Node Exporter Full | 1860 |
| Nginx Ingress Controller | 9614 |

### 9.6 Re-enroll Longhorn PVCs in recurring backup jobs

After ArgoCD syncs the `longhorn` app, the `RecurringJob` resources are created. New PVCs created by GitOps (not restored from backup) need the annotation applied:

```bash
# List all Longhorn-backed PVCs
kubectl get pvc -A | grep longhorn

# For each PVC that should be backed up (all -lh PVCs), confirm the annotation:
kubectl get pvc <name> -n <namespace> -o jsonpath='{.metadata.annotations}'
# Look for: recurring-job-group.longhorn.io/default: enabled

# If missing, add it:
kubectl annotate pvc <name> -n <namespace> \
  "recurring-job-group.longhorn.io/default=enabled"
```

### 9.7 Rotate the ArgoCD admin password

```bash
# Login via CLI first
argocd login argo.in.alybadawy.com --username admin

# Update password
argocd account update-password

# Delete the initial secret once rotated
kubectl -n argocd delete secret argocd-initial-admin-secret
```

---

## Troubleshooting

### ArgoCD app stuck in OutOfSync or Degraded

```bash
kubectl describe application <name> -n argocd
# Look at the "Message" field under Status.Conditions

# Force a manual sync
kubectl patch application <name> -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

### ExternalSecret shows SecretSyncError

The secret it references doesn't exist in the `secrets` namespace yet.

```bash
kubectl describe externalsecret <name> -n <namespace>
# "secret ... not found in namespace secrets" means you need to seed it (Phase 4)

# Verify which secret is missing
kubectl get externalsecret <name> -n <namespace> \
  -o jsonpath='{.spec.data[*].remoteRef.key}' | tr ' ' '\n' | sort -u

# After seeding, force ESO to re-sync
kubectl annotate externalsecret <name> -n <namespace> \
  force-sync=$(date +%s) --overwrite
```

### cert-manager certificate stays NotReady

```bash
kubectl describe order -n <namespace>
# If DNS-01 challenge is pending, check the Cloudflare token:
kubectl get secret cloudflare-api-token -n networking \
  -o jsonpath='{.data.api-token}' | base64 -d

# Wait for ACME challenge to propagate (~60s), or check cert-manager logs:
kubectl logs -n networking deploy/cert-manager | tail -50
```

### Longhorn volume restore took too long or timed out

```bash
# Check volume restore status in the Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 9000:80
# open http://localhost:9000 → Volumes

# Or via API
curl -s http://localhost:9000/v1/volumes/<volume-name> | jq '.state,.restoreStatus'
```

### PostgreSQL pod in CrashLoopBackOff after restore

Usually a permissions issue on the data directory from the Longhorn restore.

```bash
kubectl describe pod -n db -l app.kubernetes.io/name=postgres
# Check Events section

# The init container should handle permissions — if it failed:
kubectl logs -n db -l app.kubernetes.io/name=postgres -c fix-permissions
```

---

## Quick Reference: Full Command Sequence

For a clean rebuild, run these commands in order (filling in the values at each prompt):

```bash
# 1. On the new server — create homelab user, configure sudo, install SSH key

# 2. From your local machine (repo root):
./provision/provision-server.sh

# 3. Create secrets namespace
kubectl create namespace secrets

# 4. Seed all secrets (run bw CLI or manual kubectl commands — see Phase 4)
#    Minimum required before continuing:
kubectl create secret generic vaultwarden-admin --namespace=secrets \
  --from-literal=ADMIN_TOKEN="$(openssl rand -base64 48)" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
#   ... plus all remaining secrets in Phase 4

# 5. Bootstrap ArgoCD
./provision/bootstrap-argocd.sh

# 6. Restore Longhorn volumes
./provision/restore-volumes.sh

# 7. Activate GitOps
./provision/activate-gitops.sh

# 8. Watch and wait
kubectl get applications -n argocd -w

# 9. Verify (Phase 8–9 above)
```

---

## Related Documents

- `docs/secrets-rebuild-reference.md` — complete secret inventory and `kubectl` commands
- `docs/vaultwarden-secrets-management.md` — how to add/rotate secrets via bw CLI
- `provision/README.md` — provisioning script reference
- `CLAUDE.md` — project overview and phase descriptions
