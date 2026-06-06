# 1Password Connect Migration Plan

Migrate the ESO secrets backend from the manual `kubernetes` provider (seeding into the `secrets` namespace) to the `onepassword` provider backed by a self-hosted 1Password Connect server running in the cluster.

**Date:** 2026-06-06  
**Status:** Planned — not yet executed  
**Decision rationale:** `docs/adr/ADR-001-1password-connect-secrets-backend.md`

---

## Current State

```
Vaultwarden → bw CLI (manual) → k8s Secret in `secrets` ns → ESO (kubernetes provider) → app ns
```

- `ClusterSecretStore/k8s-secrets` uses the `kubernetes` provider reading from the `secrets` namespace
- `ServiceAccount/eso-secrets-reader` + `Role` + `RoleBinding` grant ESO read access to that namespace
- 9 secrets manually seeded in `secrets` namespace before any app can start
- Any rotation or new secret requires a human to run `bw CLI` + `kubectl apply`

## Target State

```
1Password (app/web UI) → 1Password Connect (in-cluster pod) → ESO (onepassword provider) → app ns
```

- `ClusterSecretStore/k8s-secrets` uses the `onepassword` provider pointing at the in-cluster Connect server
- 1Password Connect runs as an ArgoCD-managed application in its own namespace
- No `secrets` namespace
- No ESO RBAC (ServiceAccount/Role/RoleBinding removed)
- Rotation: update in 1Password → ESO auto-refreshes within one `refreshInterval` cycle
- Rebuild: seed one credential file + one token, everything else is automated

---

## Secrets Inventory

The following secrets currently live in the `secrets` namespace and must be migrated to 1Password items before executing the migration. Each row maps the current k8s Secret name + key to the 1Password item name + field that will replace it.

| k8s Secret (current) | Key | 1Password Item Name | 1Password Field |
|---|---|---|---|
| `vaultwarden-admin` | `ADMIN_TOKEN` | `vaultwarden-admin` | `ADMIN_TOKEN` |
| `postgres-secret` | `POSTGRES_USER` | `postgres-secret` | `username` |
| `postgres-secret` | `POSTGRES_PASSWORD` | `postgres-secret` | `password` |
| `postgres-secret` | `POSTGRES_DB` | `postgres-secret` | `POSTGRES_DB` (custom field) |
| `authentik-db` | `username` | `authentik-db` | `username` |
| `authentik-db` | `password` | `authentik-db` | `password` |
| `authentik-secret` | `secret_key` | `authentik-secret` | `secret_key` (custom field) |
| `immich-db` | `username` | `immich-db` | `username` |
| `immich-db` | `password` | `immich-db` | `password` |
| `nextcloud-db` | `username` | `nextcloud-db` | `username` |
| `nextcloud-db` | `password` | `nextcloud-db` | `password` |
| `pgadmin-secret` | `PGADMIN_DEFAULT_EMAIL` | `pgadmin-secret` | `username` |
| `pgadmin-secret` | `PGADMIN_DEFAULT_PASSWORD` | `pgadmin-secret` | `password` |
| `resend-smtp` | `host` | `resend-smtp` | `host` (custom field) |
| `resend-smtp` | `port` | `resend-smtp` | `port` (custom field) |
| `resend-smtp` | `username` | `resend-smtp` | `username` |
| `resend-smtp` | `password` | `resend-smtp` | `password` |
| `resend-smtp` | `from_address` | `resend-smtp` | `from_address` (custom field) |
| `resend-smtp` | `use_tls` | `resend-smtp` | `use_tls` (custom field) |
| `grafana-admin` | `admin-user` | `grafana-admin` | `username` |
| `grafana-admin` | `admin-password` | `grafana-admin` | `password` |

---

## Step 1: 1Password Account Setup (one-time, manual)

These steps are done in the 1Password web UI at `start.1password.com`. They do not touch the cluster.

### 1.1 Create a vault

Create a dedicated vault named **`homelab`**. All cluster secrets will live here, separate from personal passwords.

### 1.2 Create all items

Create one **Login** or **Secure Note** item per row group in the secrets inventory above. Use the "1Password Item Name" column as the item name.

**Item type guide:**
- Use **Login** for items that have a natural `username` + `password` pair (e.g., `postgres-secret`, `authentik-db`, `grafana-admin`)
- Use **Secure Note** or **Login with custom fields** for items with arbitrary keys (e.g., `resend-smtp`, `postgres-secret`'s `POSTGRES_DB` field, `authentik-secret`'s `secret_key`)

For custom fields, use the **Custom Fields** section of the item. The field label must exactly match the value in the "1Password Field" column.

### 1.3 Enable 1Password Connect

1. In the 1Password web UI: **Integrations** → **1Password Connect** → **New Token**
2. Name the token `homelab-cluster`
3. Grant it access to the `homelab` vault
4. Download the `1password-credentials.json` file — **store it safely offline**, you cannot re-download it
5. Copy the **Connect token** shown after creation — store it safely too

> Both the `1password-credentials.json` and the Connect token are required for the bootstrap step (Step 4). Treat them like passwords.

---

## Step 2: Code Changes (Git)

These are the changes to make in the repository. Do not apply them to the cluster until Step 3 and Step 4 are complete.

### 2.1 Add the `onepassword` ArgoCD Application

Create `k8s/apps/onepassword.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: onepassword
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # must deploy before all other apps
spec:
  project: default
  source:
    repoURL: https://github.com/AlyBadawy/hl-beta
    targetRevision: main
    path: k8s/components/onepassword
  destination:
    server: https://kubernetes.default.svc
    namespace: onepassword
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 2.2 Add `k8s/components/onepassword/`

**`namespace.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: onepassword
  labels:
    homelab/stack: onepassword
```

**`deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: onepassword-connect
  namespace: onepassword
spec:
  replicas: 1
  selector:
    matchLabels:
      app: onepassword-connect
  template:
    metadata:
      labels:
        app: onepassword-connect
    spec:
      containers:
        - name: connect-api
          image: 1password/connect-api:1.7.3
          ports:
            - containerPort: 8080
          env:
            - name: OP_SESSION
              valueFrom:
                secretKeyRef:
                  name: onepassword-connect-credentials
                  key: 1password-credentials.json
          volumeMounts:
            - name: data
              mountPath: /home/opuser/.op/data
        - name: connect-sync
          image: 1password/connect-sync:1.7.3
          ports:
            - containerPort: 8081
          env:
            - name: OP_SESSION
              valueFrom:
                secretKeyRef:
                  name: onepassword-connect-credentials
                  key: 1password-credentials.json
          volumeMounts:
            - name: data
              mountPath: /home/opuser/.op/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: onepassword-data
```

**`service.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: onepassword-connect
  namespace: onepassword
spec:
  selector:
    app: onepassword-connect
  ports:
    - name: api
      port: 8080
      targetPort: 8080
```

**`pvc.yaml`:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: onepassword-data
  namespace: onepassword
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
```

**`kustomization.yaml`:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - pvc.yaml
```

### 2.3 Update the ClusterSecretStore

Replace the contents of `k8s/components/external-secrets/cluster-secret-store.yaml` with:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: k8s-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  provider:
    onepassword:
      connectHost: http://onepassword-connect.onepassword.svc.cluster.local:8080
      vaults:
        homelab: 1          # vault name → priority
      auth:
        secretRef:
          connectTokenSecretRef:
            name: onepassword-connect-token
            namespace: onepassword
            key: token
```

Remove the `ServiceAccount`, `Role`, and `RoleBinding` resources from the same file — they were only needed for the `kubernetes` provider.

### 2.4 Update all ExternalSecret `remoteRef` sections

The `remoteRef.key` currently holds the k8s Secret name in the `secrets` namespace. With the 1Password provider it holds the 1Password item name. The `remoteRef.property` holds the field label within that item.

Use the mapping table in the Secrets Inventory above. For each `ExternalSecret` file:

**`k8s/components/db/external-secrets.yaml`** — update `remoteRef` for each of the 5 ExternalSecrets:

```yaml
# postgres-secret
remoteRef:
  key: postgres-secret
  property: username      # was: POSTGRES_USER
# ...
  key: postgres-secret
  property: password      # was: POSTGRES_PASSWORD
# ...
  key: postgres-secret
  property: POSTGRES_DB   # custom field — label must match exactly

# authentik-db, immich-db, nextcloud-db, pgadmin-secret — same pattern
```

**`k8s/components/auth/external-secret.yaml`** — `authentik-secret.secret_key` becomes a custom field:

```yaml
remoteRef:
  key: authentik-secret
  property: secret_key    # custom field in 1Password item
```

All other `remoteRef` entries that already use `username`/`password` field names will work without changes, as long as the 1Password item is a Login type.

### 2.5 Add `onepassword` to `k8s/apps/root.yaml` (if not auto-discovered)

Confirm that `root.yaml` watches the entire `k8s/apps/` directory. If it does, no change is needed — `onepassword.yaml` will be picked up automatically.

---

## Step 3: Pre-Apply Verification

Before pushing to `main`, verify locally that the kustomize build renders correctly:

```bash
kustomize build --enable-helm k8s/components/external-secrets | grep -A 20 "ClusterSecretStore"
kustomize build k8s/components/onepassword
```

Confirm the ClusterSecretStore shows `onepassword` as the provider and that the Connect service URL is correct.

---

## Step 4: Bootstrap Secrets (manual, on the cluster)

These two secrets must exist before ArgoCD syncs — they cannot be managed by ESO because ESO depends on them.

```bash
# Create the namespace (ArgoCD will also create it on sync, but we need it now)
kubectl create namespace onepassword --dry-run=client -o yaml | kubectl apply -f -

# 1. The credentials file — contents of the downloaded 1password-credentials.json
kubectl create secret generic onepassword-connect-credentials \
  --namespace=onepassword \
  --from-file=1password-credentials.json=/path/to/1password-credentials.json \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. The Connect token — the token string from the 1Password web UI
kubectl create secret generic onepassword-connect-token \
  --namespace=onepassword \
  --from-literal=token="<YOUR_CONNECT_TOKEN>" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secrets -n onepassword
# Expected: onepassword-connect-credentials, onepassword-connect-token
```

---

## Step 5: Apply (merge to main)

Push the code changes from Step 2 to `main`. ArgoCD will detect the changes and sync in wave order:

1. `onepassword` (wave `-1`) — Connect server deploys and authenticates
2. `external-secrets` (wave `1`) — ClusterSecretStore switches to 1Password provider
3. All other apps — ESO re-syncs ExternalSecrets from 1Password

Watch the rollout:

```bash
kubectl get applications -n argocd -w
kubectl get externalsecrets -A -w
```

All ExternalSecrets should reach `SecretSynced` within a few minutes of Connect becoming ready.

---

## Step 6: Verify

```bash
# Connect pod is running
kubectl get pods -n onepassword

# ClusterSecretStore is Ready
kubectl get clustersecretstore k8s-secrets

# All ExternalSecrets synced
kubectl get externalsecrets -A
# All should show READY=True, STATUS=SecretSynced

# Spot-check a specific secret was distributed correctly
kubectl get secret postgres-secret -n db -o jsonpath='{.data.POSTGRES_USER}' | base64 -d
```

If any ExternalSecret shows a sync error:

```bash
kubectl describe externalsecret <name> -n <namespace>
# Common issue: 1Password item name or field label doesn't match remoteRef
```

---

## Step 7: Cleanup

Once all ExternalSecrets are synced and all applications are healthy, remove the old infrastructure:

```bash
# Delete the secrets namespace and its contents
kubectl delete namespace secrets

# Confirm the ESO RBAC is gone (was removed in the git change — ArgoCD prune handles this)
kubectl get serviceaccount eso-secrets-reader -n security 2>/dev/null \
  && echo "still exists — check ArgoCD prune settings" \
  || echo "removed"
```

Update `docs/rebuild-guide.md` to reflect the new bootstrap sequence (Step 4 of the migration replaces the entire Phase 4 in the rebuild guide).

Update `docs/secrets-rebuild-reference.md` to replace the 9-secret table with the two Connect bootstrap secrets.

---

## New Rebuild Sequence (post-migration)

Once this migration is complete, the bootstrap step in `docs/rebuild-guide.md` becomes:

```bash
# 1. Provision server
./provision/provision-server.sh

# 2. Seed the two Connect bootstrap secrets
kubectl create namespace onepassword
kubectl create secret generic onepassword-connect-credentials \
  --namespace=onepassword \
  --from-file=1password-credentials.json=/path/to/1password-credentials.json \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic onepassword-connect-token \
  --namespace=onepassword \
  --from-literal=token="<CONNECT_TOKEN>" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

# 3. Bootstrap ArgoCD (Cloudflare token prompt unchanged)
./provision/bootstrap-argocd.sh

# 4. Restore Longhorn volumes
./provision/restore-volumes.sh

# 5. Activate GitOps — Connect deploys first (wave -1), then everything else
./provision/activate-gitops.sh
```

Nine manual secrets reduced to two. Both are stable credentials that never rotate unless explicitly revoked.
