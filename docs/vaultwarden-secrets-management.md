# Secrets Management with Vaultwarden and External Secrets Operator

## Overview

This cluster uses a two-layer approach to secrets management:

- **Vaultwarden** (`https://vault.in.alybadawy.com`) — self-hosted Bitwarden password manager. The human-facing source of truth. You store, rotate, and audit all secrets here.
- **External Secrets Operator (ESO)** — the k8s-facing bridge. It reads secrets from a dedicated `secrets` namespace (seeded from Vaultwarden via the `bw` CLI) and distributes them into application namespaces as native k8s `Secret` resources.

**Why this approach:**
- No plaintext secrets ever enter git
- One place to manage and rotate credentials
- Applications declare *what* secrets they need (via `ExternalSecret` manifests in git) without embedding *values*
- ESO auto-refreshes secrets on a configurable interval

```
Vaultwarden (web UI / bw CLI)
       │
       │  bw CLI — you run this once per secret, or on rotation
       ▼
 k8s Secret in `secrets` ns       ← manually seeded, never in git
       │
       │  ESO ClusterSecretStore (k8s-secrets)
       ▼
 k8s Secret in app ns             ← created/owned by ESO, never in git
       │
       ▼
   Application Pod
```

---

## What's Already Deployed

The ESO infrastructure is live. You do not need to set it up — it's managed by ArgoCD.

| Resource | Location in Git | Status |
|---|---|---|
| `ClusterSecretStore/k8s-secrets` | `k8s/components/external-secrets/cluster-secret-store.yaml` | Deployed |
| `ServiceAccount/eso-secrets-reader` | same file | Deployed in `external-secrets` ns |
| `Role/eso-secrets-reader` | same file | Deployed in `secrets` ns |
| `ExternalSecret/vaultwarden-admin` | `k8s/components/vaultwarden/external-secret.yaml` | Deployed in `vaultwarden` ns |

The `ClusterSecretStore` uses the **Kubernetes provider** — ESO authenticates as the `eso-secrets-reader` ServiceAccount and reads `Secret` resources from the `secrets` namespace.

---

## 1. First-Time Vaultwarden Setup

### Access the admin panel

```
https://vault.in.alybadawy.com/admin
```

The admin token is stored in the `vaultwarden-admin` secret in the `secrets` namespace (managed via ESO — see `docs/secrets-rebuild-reference.md` for the bootstrap command). Retrieve it with:

```bash
kubectl get secret vaultwarden-admin -n secrets \
  -o jsonpath="{.data.ADMIN_TOKEN}" | base64 -d; echo
```

### Create your user account

1. In the admin panel → **Users** → **Invite User** → enter your email.
2. Open the invitation link and complete registration.
3. Log in at `https://vault.in.alybadawy.com`.

### Create an Organization and Collections

Secrets are scoped to **Collections** inside an **Organization**.

1. **New Organization** → name it `homelab`.
2. Create one **Collection per concern**:

| Collection | Contents |
|---|---|
| `cluster-secrets` | Catch-all for cluster-wide credentials |
| `cert-manager` | Cloudflare API token for DNS-01 TLS challenges |
| `smtp` | SMTP username and password (when needed) |
| `vaultwarden` | Vaultwarden admin token itself |

---

## 2. Storing a Secret in Vaultwarden

1. Open the `homelab` organization → select the appropriate Collection.
2. **New Item** → choose the type:
   - **Login** for username + password pairs (e.g., SMTP credentials)
   - **Secure Note** for single values or tokens (e.g., API tokens)
3. Name the item to match the k8s Secret name you'll create (e.g., `cloudflare-api-token`).
4. For API tokens or arbitrary values, use the **Notes** field or a **Custom Field**.

---

## 3. Seeding a Secret into Kubernetes

Install the Bitwarden CLI and point it at your Vaultwarden instance:

```bash
# Install bw CLI (macOS)
brew install bitwarden-cli

# Point bw at your self-hosted Vaultwarden
bw config server https://vault.in.alybadawy.com

# Login and unlock the vault
bw login
export BW_SESSION=$(bw unlock --raw)
```

Seed a secret into the `secrets` namespace. The pattern — pull the value from Vaultwarden, create or update a k8s `Secret`:

```bash
# Secure Note item (e.g., an API token stored in the Notes field)
kubectl create secret generic cloudflare-api-token \
  --namespace=secrets \
  --from-literal=api-token="$(bw get notes 'cloudflare-api-token' --session $BW_SESSION)" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

# Login item (username + password)
kubectl create secret generic smtp-credentials \
  --namespace=secrets \
  --from-literal=username="$(bw get username 'smtp-credentials' --session $BW_SESSION)" \
  --from-literal=password="$(bw get password 'smtp-credentials' --session $BW_SESSION)" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

These commands are **idempotent** — re-run them anytime a credential rotates in Vaultwarden.

---

## 4. Adding an ExternalSecret for an Application

An `ExternalSecret` is a GitOps-safe manifest declaring *which* secret an app needs. ESO creates the actual k8s `Secret` from it. Commit the `ExternalSecret` to git — the values never appear there.

Add an `ExternalSecret` to the application's component directory and include it in its `kustomization.yaml`.

**Template:**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <secret-name>
  namespace: <app-namespace>
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: k8s-secrets
    kind: ClusterSecretStore
  target:
    name: <secret-name>        # name of the k8s Secret ESO will create
    creationPolicy: Owner
  data:
    - secretKey: <key>         # key in the created Secret
      remoteRef:
        key: <secret-name>     # name of the Secret in the `secrets` namespace
        property: <key>        # key within that Secret
```

**Live example** — Vaultwarden admin token (`k8s/components/vaultwarden/external-secret.yaml`):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vaultwarden-admin
  namespace: vaultwarden
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: k8s-secrets
    kind: ClusterSecretStore
  target:
    name: vaultwarden-admin
    creationPolicy: Owner
  data:
    - secretKey: ADMIN_TOKEN
      remoteRef:
        key: vaultwarden-admin   # Secret in `secrets` ns
        property: ADMIN_TOKEN
```

**Example — SMTP credentials for a future app:**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: smtp-credentials
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: k8s-secrets
    kind: ClusterSecretStore
  target:
    name: smtp-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: smtp-credentials
        property: username
    - secretKey: password
      remoteRef:
        key: smtp-credentials
        property: password
```

Reference the resulting secret from a Pod:

```yaml
env:
  - name: SMTP_USERNAME
    valueFrom:
      secretKeyRef:
        name: smtp-credentials
        key: username
  - name: SMTP_PASSWORD
    valueFrom:
      secretKeyRef:
        name: smtp-credentials
        key: password
```

---

## 5. Rotating a Secret

1. Update the value in Vaultwarden.
2. Re-run the `bw` + `kubectl apply` command from [Section 3](#3-seeding-a-secret-into-kubernetes) to update the Secret in the `secrets` namespace.
3. ESO detects the change on its next poll (`refreshInterval`) and updates all consumer Secrets automatically. To force an immediate refresh:
   ```bash
   kubectl annotate externalsecret <name> -n <namespace> \
     force-sync=$(date +%s) --overwrite
   ```

---

## 6. Secret Inventory

| Secret in `secrets` ns | Key(s) | ExternalSecret in git | Consuming app |
|---|---|---|---|
| `vaultwarden-admin` | `ADMIN_TOKEN` | `k8s/components/vaultwarden/external-secret.yaml` | `vaultwarden` ns |

Add a row here whenever a new secret is wired up through ESO.

---

## 7. Verify the Setup

```bash
# Check the ClusterSecretStore is ready
kubectl get clustersecretstore k8s-secrets

# List all ExternalSecrets and their sync status
kubectl get externalsecrets --all-namespaces

# Check a specific ExternalSecret
kubectl describe externalsecret vaultwarden-admin -n vaultwarden

# Confirm ESO created the target Secret
kubectl get secret vaultwarden-admin -n vaultwarden

# ESO operator logs
kubectl logs -n external-secrets deployment/external-secrets --tail=50
```

---

**Last Updated:** 2026-06-04
