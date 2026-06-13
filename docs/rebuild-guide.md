# Cluster Rebuild Guide

Step-by-step instructions for rebuilding the entire cluster on a new node and restoring all data from backups. Follow these steps in order — skipping or reordering them will cause dependency failures.

**Last Updated:** 2026-06-06  
**Applies to:** k3s v1.36.1, ArgoCD on main branch, single-node cluster

---

## Before You Start

### What is automatically restored

| Data                                                | Backup mechanism                                            | Restored in step                       |
| --------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------- |
| Vault KV secrets (all app credentials)              | Longhorn PVC backup (`vault-data`) → NAS                    | Step 6                                 |
| PostgreSQL databases (authentik, immich, nextcloud) | Daily `pg_dump` → NAS (`/mnt/nas/backups/postgres`)         | Step 8 (manual)                        |
| Longhorn volumes (all `-lh` PVCs)                   | Longhorn backup every 6h → NAS                              | Step 6                                 |
| Immich photos                                       | NAS (`/mnt/nas/immich`) — live, not backed up separately    | Available immediately after NAS mounts |
| Nextcloud files                                     | NAS (`/mnt/nas/nextcloud`) — live, not backed up separately | Available immediately after NAS mounts |
| Grafana dashboards                                  | `local-path` PVC — NOT backed up by Longhorn                | Must be re-imported manually           |
| Prometheus metrics history                          | `local-path` PVC — NOT backed up                            | Lost on rebuild (expected)             |

### What requires manual intervention

These values are never stored in git and must be supplied from your offline backup / password manager before the cluster can sync:

| Credential                             | Where it's needed                       |
| -------------------------------------- | --------------------------------------- |
| New node IP address                    | All provisioning scripts                |
| SSH private key for `homelab` user     | Your local `~/.ssh/`                    |
| Vault unseal key (from offline backup) | `rebuild.sh` Step 6 — prompted at start |
| Cloudflare API token (Zone:DNS:Edit)   | `rebuild.sh` Step 7 — prompted at start |

### Required tools on your local machine

```bash
# Verify these are installed before starting
kubectl version --client
kustomize version
helm version
jq --version
```

---

## Step 1: Prepare the New Node

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

If the NAS is unreachable, do not proceed — rebuild.sh Step 3 (NAS mounts) will fail, and Immich/Nextcloud data will not be accessible.

---

## Step 2: Server Provisioning

From your **local machine**, in the repo root:

```bash
cd ~/hl-beta
./provision/rebuild.sh
```

When prompted:

- **Server IP:** enter the new node's IP
- **Vault unseal key:** from your offline backup / password manager
- **Cloudflare API token:** Zone:DNS:Edit for `alybadawy.com`

`rebuild.sh` runs all steps unattended from this point. It covers Steps 1–8 (server
provisioning, secret seeding, ArgoCD bootstrap, Longhorn install + volume restore).

| Step | Script                 | What it does                                                                   |
| ---- | ---------------------- | ------------------------------------------------------------------------------ |
| 1    | `check-ssh-connection` | Validates SSH + NOPASSWD sudo                                                  |
| 2    | `update-dependencies`  | `apt upgrade`, installs packages incl. `open-iscsi`, disables swap             |
| 3    | `mount-nas`            | Creates `/mnt/nas/{homelab,backups,immich,nextcloud}`, adds NFS fstab entries  |
| 4    | `install-k3s`          | Installs k3s v1.36.1 (Traefik disabled), copies kubeconfig to `~/.kube/config` |
| 5    | `configure-cluster`    | Creates `cluster-config` namespace and ConfigMap, applies kernel tuning        |

When Steps 1–5 complete, verify:

```bash
kubectl get nodes
# Expected: node in Ready state

kubectl get configmap cluster-config -n cluster-config
# Expected: configmap with domain, NAS paths, admin email, server IP
```

---

## Step 3: Seed the Vault Unseal Key (handled by rebuild.sh)

The Vault unseal key must exist before ArgoCD runs. When GitOps activates, Vault starts first (sync-wave `-1`) and the `vault-auto-unseal` CronJob uses this secret to unseal it within 60 seconds. Without it, Vault stays sealed, ESO cannot sync, and all apps fail to start.

On a rebuild, Vault's data volume (`vault-data`) is restored from the Longhorn backup — so all KV secrets are already inside Vault. You only need to provide the unseal key to let the CronJob open it.

**`rebuild.sh` handles this automatically** (Step 6) — it prompts for the unseal key at the start and seeds it after the k3s cluster is up. For reference, the commands it runs are:

```bash
kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vault-unseal-key \
  --namespace=security \
  --from-literal=key="<UNSEAL_KEY_FROM_OFFLINE_BACKUP>" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

> The unseal key was generated during the initial `vault operator init` run. It must be stored offline (password manager, printed copy). Without it, Vault cannot be unsealed on restart.

---

## Step 4: Required Secrets Reference

Only **two secrets** require manual intervention on a rebuild. Everything else is either seeded automatically or lives inside Vault (which is restored from the Longhorn backup in Step 6).

| Secret                 | Namespace    | How it's created                        | Why it's needed                                                 |
| ---------------------- | ------------ | --------------------------------------- | --------------------------------------------------------------- |
| `vault-unseal-key`     | `security`   | `rebuild.sh` Step 6 (prompted at start) | CronJob unseals Vault within 60s of each pod restart            |
| `cloudflare-api-token` | `networking` | `rebuild.sh` Step 7 (prompted at start) | DNS-01 TLS challenges for `*.in.alybadawy.com` via cert-manager |

**All other app secrets** (postgres credentials, authentik secret key, immich credentials, nextcloud credentials, SMTP, grafana admin, etc.) are stored in Vault's KV store at `secret/`. ESO reads them from Vault and distributes copies into each app namespace automatically. Because Vault's data PVC is part of the Longhorn backup, no manual seeding of these secrets is required.

### 4.1 vault-unseal-key

Created by `rebuild.sh` Step 6. Verify it exists before continuing:

```bash
kubectl get secret vault-unseal-key -n security
```

### 4.2 cloudflare-api-token

Created by `rebuild.sh` Step 7 (`provision/scripts/bootstrap-argocd`). For reference, the commands it runs:

```bash
kubectl create namespace networking --dry-run=client -o yaml | kubectl apply -f -
kubectl -n networking create secret generic cloudflare-api-token \
  --from-literal=api-token="<CLOUDFLARE_API_TOKEN>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The token must have **Zone → DNS → Edit** permission for the `alybadawy.com` zone.

### 4.3 Verify after rebuild.sh

After `rebuild.sh` completes through Step 7, confirm both secrets are present:

```bash
kubectl get secret vault-unseal-key -n security
kubectl get secret cloudflare-api-token -n networking
```

---

## Step 5: Bootstrap ArgoCD (handled by rebuild.sh)

`rebuild.sh` runs `provision/scripts/bootstrap-argocd` automatically as Step 7 using
the Cloudflare token you entered at the start. No separate invocation is needed.

For reference, this step:

1. Installs ArgoCD from `k8s/components/argocd` via Kustomize + Helm
2. Waits for `argocd-server` and `argocd-repo-server` to be ready
3. Creates the `networking` namespace and seeds `cloudflare-api-token` into it (used by cert-manager for DNS-01 challenges)

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

## Step 6: Install Longhorn and Restore Volumes (handled by rebuild.sh)

`rebuild.sh` runs `provision/scripts/restore-volumes` automatically as Step 8.
The script will ask:

> **Is this a fresh cluster with no backups to restore? [y/N]**

- Answer **`n`** (default) to restore from NAS backups — this is what you want for a rebuild.
- Answer **`y`** only on a first-ever install with no existing data.

### What the script does

1. Installs Longhorn from `k8s/components/longhorn`
2. Waits for Longhorn to be ready
3. Applies the BackupTarget (pointing at `nfs://172.20.20.2:/var/nfs/shared/backups/pvcs`) and RecurringJob resources
4. Opens the Longhorn UI via port-forward on `http://localhost:9000`
5. **Waits for you to restore volumes manually through the UI**
6. Exits once you confirm the restore is complete

### Manual restore steps (in the Longhorn UI)

With `http://localhost:9000` open in your browser:

1. Click **Backup** in the left sidebar
2. If no backup volumes appear, click the sync icon to refresh from the NAS
3. For each backup volume, select the latest backup entry and click **Restore**
4. When prompted for a volume name, use the **PVC name** from the table below
5. After restoring all volumes, go to **Volume** and confirm each shows state **Detached**
6. For each restored volume, click **Create PV/PVC** — set the correct **namespace** and **PVC name** from the table

### Volume → namespace/PVC mapping

| Backup volume (shown in UI)              | Namespace  | PVC name              |
| ---------------------------------------- | ---------- | --------------------- |
| `pvc-cc69b622-...` (vault)               | `security` | `vault-data`          |
| `pvc-156223fb-...` (postgres)            | `db`       | `postgres-data`       |
| `pvc-6b246721-...` (nextcloud)           | `cloud`    | `nextcloud-config`    |
| `pvc-fa03ae85-...` (authentik media)     | `security` | `authentik-media`     |
| `pvc-5081ced2-...` (authentik templates) | `security` | `authentik-templates` |

> The backup volume names in the UI are the internal Longhorn IDs (long UUIDs). The `lastBackupName` field and the Longhorn UI label can help you identify which is which by size. If unsure, check the `volumeName` shown in each backup volume's detail page.

Once all PVCs are created, press **Enter** in the terminal to let the script confirm and exit.

After the script exits, verify the PVCs exist:

```bash
kubectl get pvc -A | grep -E "lh$"
```

All PVCs should show `Bound` status.

---

## Step 7: Activate GitOps

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

1. `vault` — Vault StatefulSet starts (wave `-1`); CronJob unseals it within 60s using `vault-unseal-key`
2. `external-secrets` — ESO operator deploys; `ClusterSecretStore/k8s-secrets` connects to Vault and becomes Ready
3. `cert-manager` — cert-manager deploys; ClusterIssuers created; TLS certs begin issuing via DNS-01
4. `ingress-nginx` — nginx controller gets an external IP; ingress routes become active
5. `db` — PostgreSQL deploys with restored `postgres-data` PVC; ESO syncs credentials from Vault
6. `auth` — Authentik deploys with restored media PVCs; ESO syncs SMTP and secret key from Vault
7. `cloud` — Nextcloud deploys with restored `nextcloud-config` PVC
8. `immich` — Immich deploys; photos immediately available from NAS mount
9. `monitor` — Prometheus + Grafana deploy; ESO syncs Grafana admin password from Vault
10. `aly`, `whoami` — static sites deploy

Allow 10–15 minutes for all apps to reach `Synced / Healthy`.

---

## Step 8: Restore PostgreSQL Databases

Longhorn restores the PostgreSQL _data volume_, which should contain all databases intact. However, if the Longhorn backup was taken when PostgreSQL was mid-write (unlikely with the daily pg_dump schedule, but possible), you may need to fall back to the pg_dump backups.

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

## Step 9: Post-Rebuild Verification

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

| Service   | URL                                 | What to check                                |
| --------- | ----------------------------------- | -------------------------------------------- |
| ArgoCD    | `https://argo.in.alybadawy.com`     | Login with admin; all apps green             |
| Vault     | `https://vault.in.alybadawy.com`    | UI loads; status shows unsealed              |
| Authentik | `https://auth.in.alybadawy.com`     | Login; users and flows intact                |
| Immich    | `https://immich.in.alybadawy.com`   | Login; photos visible                        |
| Nextcloud | `https://cloud.in.alybadawy.com`    | Login; files accessible                      |
| Longhorn  | `https://longhorn.in.alybadawy.com` | All volumes healthy; backup target connected |
| Grafana   | `https://grafana.in.alybadawy.com`  | Login; dashboards load                       |

### 9.5 Restore Grafana dashboards

Grafana uses a `local-path` PVC which is **not** backed up by Longhorn. Dashboards must be re-imported.

```bash
# Port-forward if ingress isn't up yet
kubectl port-forward -n monitor svc/monitor-grafana 3000:80

# Then import dashboards from grafana.com using their IDs, or from JSON exports
# if you exported them before the rebuild.
```

Recommended dashboards to re-import from grafana.com:

| Dashboard                   | ID    |
| --------------------------- | ----- |
| Kubernetes cluster overview | 7249  |
| Longhorn                    | 16888 |
| Node Exporter Full          | 1860  |
| Nginx Ingress Controller    | 9614  |

### 9.6 Re-enroll Longhorn PVCs in recurring backup jobs

After ArgoCD syncs the `longhorn` app, the `RecurringJob` resources are created. New PVCs created by GitOps (not restored from backup) need the annotation applied:

```bash
# List all Longhorn-backed PVCs
kubectl get pvc -A | grep longhorn

# For each PVC that should be backed up (all PVCs), confirm the annotation:
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
# "secret ... not found in namespace secrets" means you need to seed it (Step 4)

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

# 2. From your local machine (repo root) — Steps 1–8:
#    Prompted upfront: server IP, Vault unseal key, Cloudflare API token
./provision/rebuild.sh

# 3. Activate GitOps (Vault starts → CronJob unseals → ESO syncs all secrets → apps start)
./provision/activate-gitops.sh

# 4. Watch and wait
kubectl get applications -n argocd -w

# 5. Verify (Steps 8–9 above)
```

---

## Related Documents

- `docs/secrets-rebuild-reference.md` — complete secret inventory, offline checklist, and `kubectl` commands
- `provision/README.md` — provisioning script reference
- `CLAUDE.md` — project overview and step descriptions
