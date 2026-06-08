# HashiCorp Vault Migration Plan

Migrate the ESO secrets backend from the manual `kubernetes` provider (seeding into the `secrets` namespace) to the `vault` provider backed by a self-hosted HashiCorp Vault server running in the cluster.

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
Vault KV (in-cluster) → ESO (vault provider) → app namespace
```

- HashiCorp Vault runs as a StatefulSet in the `vault` namespace, backed by a Longhorn PVC
- Secrets stored as flat **key/value pairs** in Vault's KV v2 engine under `secret/`
- `ClusterSecretStore/k8s-secrets` uses the `vault` provider with Kubernetes auth
- A Kubernetes CronJob auto-unseals Vault within 60s of a reboot
- No `secrets` namespace
- Rotation: `vault kv patch secret/<path> key=newvalue` → ESO picks up on next refresh
- Rebuild: seed one unseal-key k8s Secret, everything else comes from the Longhorn backup

---

## Secrets Inventory

All secrets are stored in Vault KV v2 under the `secret/` mount as key/value pairs. Each path is one logical secret group.

| Vault Path | Key | Value (example / description) |
|---|---|---|
| `secret/postgres-secret` | `POSTGRES_USER` | PostgreSQL superuser name |
| `secret/postgres-secret` | `POSTGRES_PASSWORD` | PostgreSQL superuser password |
| `secret/postgres-secret` | `POSTGRES_DB` | Default database name |
| `secret/authentik-db` | `username` | Authentik DB username |
| `secret/authentik-db` | `password` | Authentik DB password |
| `secret/authentik-secret` | `secret_key` | Authentik cryptographic signing key |
| `secret/immich-db` | `username` | Immich DB username |
| `secret/immich-db` | `password` | Immich DB password |
| `secret/nextcloud-db` | `username` | Nextcloud DB username |
| `secret/nextcloud-db` | `password` | Nextcloud DB password |
| `secret/pgadmin-secret` | `PGADMIN_DEFAULT_EMAIL` | pgAdmin login email |
| `secret/pgadmin-secret` | `PGADMIN_DEFAULT_PASSWORD` | pgAdmin login password |
| `secret/resend-smtp` | `host` | SMTP server hostname |
| `secret/resend-smtp` | `port` | SMTP port |
| `secret/resend-smtp` | `username` | SMTP username |
| `secret/resend-smtp` | `password` | SMTP password |
| `secret/resend-smtp` | `from_address` | Sender email address |
| `secret/resend-smtp` | `use_tls` | `"true"` or `"false"` |
| `secret/grafana-admin` | `admin-user` | Grafana admin username |
| `secret/grafana-admin` | `admin-password` | Grafana admin password |

---

## Step 1: Code Changes (Git)

Make all code changes in a feature branch. Do **not** merge to `main` until Steps 2 and 3 (bootstrap and seeding) are complete — merging before Vault is initialized will cause ESO to fail and apps to lose secret sync.

### 1.1 Add the `vault` ArgoCD Application

Create `k8s/apps/vault.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # deploys before ESO and all apps
spec:
  project: default
  source:
    repoURL: https://github.com/AlyBadawy/hl-beta
    targetRevision: main
    path: k8s/components/vault
  destination:
    server: https://kubernetes.default.svc
    namespace: vault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 1.2 Add `k8s/components/vault/`

**`namespace.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
  labels:
    homelab/stack: vault
```

**`values.yaml`** (Vault Helm values):
```yaml
server:
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address     = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "file" {
        path = "/vault/data"
      }

  dataStorage:
    enabled: true
    storageClass: longhorn
    size: 5Gi

  # Ingress is managed as a standalone Ingress resource in ingress.yaml,
  # consistent with the rest of the cluster. TLS is handled globally by
  # ingress-nginx via the shared wildcard cert (networking/wildcard-tls);
  # no per-hostname cert or cert-manager annotation is needed here.
  ingress:
    enabled: false

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 250m
      memory: 256Mi

ui:
  enabled: true

injector:
  enabled: false   # not needed — ESO handles secret distribution
```

**`auto-unseal-cronjob.yaml`:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-auto-unseal
  namespace: vault
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: unseal
              image: hashicorp/vault:latest
              command: ["/bin/sh", "-c"]
              args:
                - |
                  STATUS=$(vault status -format=json 2>/dev/null | jq -r '.sealed // "true"')
                  if [ "$STATUS" = "true" ]; then
                    echo "Vault is sealed — unsealing"
                    vault operator unseal "$UNSEAL_KEY"
                  else
                    echo "Vault is already unsealed — nothing to do"
                  fi
              env:
                - name: VAULT_ADDR
                  value: http://vault.vault.svc.cluster.local:8200
                - name: UNSEAL_KEY
                  valueFrom:
                    secretKeyRef:
                      name: vault-unseal-key
                      key: key
```

**`kustomization.yaml`:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: vault
    repo: https://helm.releases.hashicorp.com
    version: 0.29.1   # pin and update deliberately
    releaseName: vault
    namespace: vault
    valuesFile: values.yaml

resources:
  - namespace.yaml
  - auto-unseal-cronjob.yaml
```

### 1.3 Update the ClusterSecretStore

Replace `k8s/components/external-secrets/cluster-secret-store.yaml` entirely:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-vault-auth
  namespace: external-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: k8s-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: secret        # KV v2 mount name
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-reader
          serviceAccountRef:
            name: eso-vault-auth
            namespace: external-secrets
```

The old `eso-secrets-reader` ServiceAccount, Role, and RoleBinding that pointed at the `secrets` namespace are removed from this file entirely.

### 1.4 ExternalSecret `remoteRef` — no changes needed

With the Vault provider, `remoteRef.key` is the Vault path (without the `secret/` mount prefix) and `remoteRef.property` is the key name within that path. Since the Vault paths and key names are named identically to the current k8s Secret names and keys, **no ExternalSecret manifest needs to change**.

For reference, this is what the mapping looks like:

```yaml
# Before (kubernetes provider)
remoteRef:
  key: postgres-secret      # name of k8s Secret in `secrets` namespace
  property: POSTGRES_USER   # key within that Secret

# After (vault provider) — identical syntax, different semantic target
remoteRef:
  key: postgres-secret      # Vault path under secret/ mount
  property: POSTGRES_USER   # key within the KV v2 secret at that path
```

---

## Step 2: Bootstrap — Initialize Vault (manual, one-time)

This step runs once on the live cluster **before** merging the code changes to `main`. On future rebuilds, Vault's data is restored from the Longhorn PVC backup and this initialization is skipped.

### 2.1 Deploy Vault imperatively

```bash
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
kustomize build --enable-helm k8s/components/vault | kubectl apply -f -

# Wait for the pod to be running (it will start sealed)
kubectl rollout status statefulset/vault -n vault --timeout=120s
```

### 2.2 Initialize Vault

Use a single key share and threshold — appropriate for a single-node homelab.

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > vault-init.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

echo "Unseal key : $UNSEAL_KEY"
echo "Root token : $ROOT_TOKEN"
```

> **Save both values offline** before continuing — local password manager, printed copy, or equivalent. The unseal key is needed if the k8s Secret is ever lost. The root token is the bootstrap admin credential.

### 2.3 Unseal Vault for the first time

```bash
kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY"

# Confirm
kubectl exec -n vault vault-0 -- vault status | grep Sealed
# Sealed: false
```

### 2.4 Store the unseal key in a Kubernetes Secret

This is what the auto-unseal CronJob reads on every subsequent reboot.

```bash
kubectl create secret generic vault-unseal-key \
  --namespace=vault \
  --from-literal=key="$UNSEAL_KEY" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 2.5 Configure Vault

Port-forward Vault locally, then configure it with the root token:

```bash
kubectl port-forward -n vault svc/vault 8200:8200 &
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN="$ROOT_TOKEN"

# Enable KV v2 at the secret/ path
vault secrets enable -path=secret kv-v2

# Enable Kubernetes auth
vault auth enable kubernetes

# Trust the cluster's API server
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Policy: ESO can read all secrets
vault policy write eso-reader - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

# Role: bind the ESO ServiceAccount to the policy
vault write auth/kubernetes/role/eso-reader \
  bound_service_account_names=eso-vault-auth \
  bound_service_account_namespaces=external-secrets \
  policies=eso-reader \
  ttl=1h
```

---

## Step 3: Seed All Secrets

With Vault configured, write all secrets as key/value pairs. Each `vault kv put` call sets all keys for a path in one command.

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN="$ROOT_TOKEN"

vault kv put secret/postgres-secret \
  POSTGRES_USER="<value>" \
  POSTGRES_PASSWORD="<value>" \
  POSTGRES_DB="<value>"

vault kv put secret/authentik-db \
  username="<value>" \
  password="<value>"

vault kv put secret/authentik-secret \
  secret_key="$(openssl rand -hex 50)"
# Note: generating a new key is safe — it only invalidates existing sessions

vault kv put secret/immich-db \
  username="<value>" \
  password="<value>"

vault kv put secret/nextcloud-db \
  username="<value>" \
  password="<value>"

vault kv put secret/pgadmin-secret \
  PGADMIN_DEFAULT_EMAIL="<value>" \
  PGADMIN_DEFAULT_PASSWORD="<value>"

vault kv put secret/resend-smtp \
  host="smtp.resend.com" \
  port="587" \
  username="<value>" \
  password="<value>" \
  from_address="homelab@alybadawy.com" \
  use_tls="true"

vault kv put secret/grafana-admin \
  admin-user="admin" \
  admin-password="<value>"
```

Verify:

```bash
vault kv list secret/
# Should list all 9 paths

vault kv get secret/postgres-secret
# Should show POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB as key/value pairs
```

---

## Step 4: Apply (merge to main)

With Vault initialized, unsealed, configured, and seeded, merge the feature branch to `main`. ArgoCD syncs in wave order:

1. `vault` (wave `-1`) — Vault StatefulSet adopted by GitOps; CronJob deployed
2. `external-secrets` (wave `1`) — ClusterSecretStore switches to `vault` provider; ESO ServiceAccount created
3. All other apps — ESO re-syncs all ExternalSecrets from Vault

```bash
kubectl get applications -n argocd -w
kubectl get externalsecrets -A -w
# All should reach: READY=True, STATUS=SecretSynced
```

---

## Step 5: Verify

```bash
# Vault is running and unsealed
kubectl exec -n vault vault-0 -- vault status

# ClusterSecretStore is Ready
kubectl get clustersecretstore k8s-secrets

# All ExternalSecrets synced
kubectl get externalsecrets -A

# Spot-check a value reached its destination
kubectl get secret postgres-secret -n db \
  -o jsonpath='{.data.POSTGRES_USER}' | base64 -d; echo

# Auto-unseal CronJob is deployed
kubectl get cronjob vault-auto-unseal -n vault
```

---

## Step 6: Rotating a Secret

KV v2 automatically versions every write. To rotate:

```bash
# Update one key without touching the others
vault kv patch secret/postgres-secret \
  POSTGRES_PASSWORD="<new-password>"

# Force ESO to pick it up immediately (instead of waiting for refreshInterval)
kubectl annotate externalsecret postgres-secret -n db \
  force-sync=$(date +%s) --overwrite
```

To audit history or roll back:

```bash
vault kv metadata get secret/postgres-secret   # shows all versions
vault kv get -version=1 secret/postgres-secret  # read a specific version
```

---

## Step 7: Cleanup

```bash
# Delete the old secrets namespace
kubectl delete namespace secrets

# Confirm old ESO RBAC is gone (ArgoCD prune handles this on sync)
kubectl get serviceaccount eso-secrets-reader -n security 2>/dev/null \
  && echo "still present — check ArgoCD prune settings" \
  || echo "removed"

# Remove vault-init.json from local disk
rm vault-init.json
```

Update `docs/rebuild-guide.md` and `docs/secrets-rebuild-reference.md` to reflect the new bootstrap sequence.

---

## New Rebuild Sequence (post-migration)

On a fresh node, Vault's data volume is restored from its Longhorn backup along with all other stateful apps. Vault is already initialized — only the unseal key needs to be seeded.

```bash
# 1. Provision server, seed secrets, bootstrap ArgoCD, restore Longhorn volumes
#    Prompted upfront: server IP, Vault unseal key, Cloudflare API token
./provision/rebuild.sh

# 2. Activate GitOps
#    vault (wave -1) starts → CronJob auto-unseals within 60s
#    ESO connects to Vault → all ExternalSecrets sync → apps start
./provision/activate-gitops.sh
```

Nine manual secrets seeded on rebuild → one: the Vault unseal key.

---

## Offline Backup Checklist (post-migration)

Store these safely offline — local password manager, printed paper, or equivalent:

- [ ] **Vault unseal key** — needed if the `vault-unseal-key` k8s Secret is lost
- [ ] **Vault root token** — bootstrap admin credential; keep as a break-glass key after rotating
- [ ] **Cloudflare API token** — still needed for cert-manager DNS-01 bootstrap
