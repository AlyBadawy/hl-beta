# Secrets Management with Vaultwarden and External Secrets Operator

## Overview

This cluster uses a two-layer approach to secrets management:

- **Vaultwarden** (`https://vault.in.alybadawy.com`) — self-hosted Bitwarden password manager. The human-facing source of truth. You store, rotate, and audit all secrets here.
- **External Secrets Operator (ESO)** — the k8s-facing bridge. It reads secrets from a Kubernetes `secrets` namespace (seeded from Vaultwarden via `bw` CLI) and distributes them into application namespaces as native k8s `Secret` resources.

**Why this approach:**
- No plaintext secrets ever enter git
- One place to manage and rotate credentials
- Applications declare *what* secrets they need (via `ExternalSecret` manifests in git) without embedding *values*
- ESO auto-refreshes secrets on a configurable interval

```
Vaultwarden (web UI)
       │  bw CLI
       ▼
 k8s Secret in `secrets` ns   ← manually seeded, never in git
       │  ESO ClusterSecretStore
       ▼
 k8s Secret in app ns         ← created/owned by ESO, never in git
       │
       ▼
   Application Pod
```

---

## 1. First-Time Vaultwarden Setup

### Access the admin panel

```
https://vault.in.alybadawy.com/admin
```

The admin token is set in `k8s/components/vaultwarden/values.yaml` under `adminToken.value`. Change the placeholder before exposing the instance publicly.

### Create your user account

1. In the admin panel → **Users** → **Invite User** → enter your email.
2. Open the invitation link and complete registration.
3. Log in at `https://vault.in.alybadawy.com`.

### Create an Organization and Collections

Secrets are scoped to **Collections** inside an **Organization** — this lets you share secrets between multiple people or service accounts without exposing your personal vault.

1. **New Organization** → name it `homelab`.
2. Inside the organization, create one **Collection per concern**:

| Collection | Contents |
|---|---|
| `cluster-secrets` | Catch-all for cluster-wide credentials |
| `cert-manager` | Cloudflare API token for DNS-01 TLS challenges |
| `smtp` | SMTP username and password |
| `vaultwarden` | Vaultwarden admin token itself |

---

## 2. Storing a Secret in Vaultwarden

1. Open the `homelab` organization → select the appropriate Collection.
2. **New Item** → choose the type:
   - **Login** for username + password pairs (e.g., SMTP credentials)
   - **Secure Note** for single values or tokens (e.g., Cloudflare API token, admin tokens)
3. Name the item clearly and consistently — you'll reference this name in CLI commands (e.g., `cloudflare-api-token`, `smtp-credentials`).
4. For API tokens or arbitrary values, use the **Notes** field or add a **Custom Field**.

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

Create the `secrets` namespace (idempotent):

```bash
kubectl create namespace secrets --dry-run=client -o yaml | kubectl apply -f -
```

Seed a secret into the `secrets` namespace. The pattern is: pull the value from Vaultwarden, create (or update) a k8s `Secret`:

```bash
# Example: Cloudflare API token stored as a Secure Note in Vaultwarden
bw get notes "cloudflare-api-token" --session $BW_SESSION | \
  kubectl create secret generic cloudflare-api-token \
    --namespace=secrets \
    --from-literal=api-token="$(bw get notes 'cloudflare-api-token' --session $BW_SESSION)" \
    --save-config \
    --dry-run=client -o yaml | kubectl apply -f -

# Example: SMTP credentials stored as a Login item
kubectl create secret generic smtp-credentials \
  --namespace=secrets \
  --from-literal=username="$(bw get username 'smtp-credentials' --session $BW_SESSION)" \
  --from-literal=password="$(bw get password 'smtp-credentials' --session $BW_SESSION)" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

> These commands are **idempotent** — re-run them anytime a secret rotates in Vaultwarden.

---

## 4. ESO ClusterSecretStore

The `ClusterSecretStore` tells ESO where to look for secrets. Add the following resources to `k8s/components/external-secrets/kustomization.yaml` and create `k8s/components/external-secrets/cluster-secret-store.yaml`:

```yaml
# cluster-secret-store.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-secrets-reader
  namespace: external-secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-secrets-reader
  namespace: secrets
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-secrets-reader
  namespace: secrets
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: eso-secrets-reader
subjects:
  - kind: ServiceAccount
    name: eso-secrets-reader
    namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: k8s-secrets
spec:
  provider:
    kubernetes:
      remoteNamespace: secrets
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
          namespace: secrets
      auth:
        serviceAccount:
          name: eso-secrets-reader
          namespace: external-secrets
```

---

## 5. ExternalSecret per Application

An `ExternalSecret` is a GitOps-safe manifest that declares *which* secret an application needs and *where* to find it. ESO creates the actual k8s `Secret` from it.

Add `ExternalSecret` resources alongside the application's other Kustomize manifests.

**Example — cert-manager Cloudflare token:**

```yaml
# k8s/components/cert-manager/cloudflare-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: k8s-secrets
    kind: ClusterSecretStore
  target:
    name: cloudflare-api-token
    creationPolicy: Owner
  data:
    - secretKey: api-token
      remoteRef:
        key: cloudflare-api-token      # name of the k8s Secret in the `secrets` ns
        property: api-token            # key within that Secret
```

**Example — SMTP credentials:**

```yaml
apiVersion: external-secrets.io/v1beta1
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

## 6. Rotating a Secret

1. Update the value in Vaultwarden.
2. Re-run the corresponding `bw` + `kubectl apply` command from [Section 3](#3-seeding-a-secret-into-kubernetes) to update the Secret in the `secrets` namespace.
3. ESO detects the change on its next poll (`refreshInterval`, default 1h) and updates all consumer Secrets automatically. To force an immediate refresh:
   ```bash
   kubectl annotate externalsecret <name> -n <namespace> \
     force-sync=$(date +%s) --overwrite
   ```

---

## 7. Secret Inventory

| Vaultwarden Item | `secrets` ns Secret | Key(s) | Consuming App/Namespace |
|---|---|---|---|
| `cloudflare-api-token` | `cloudflare-api-token` | `api-token` | cert-manager |
| `smtp-credentials` | `smtp-credentials` | `username`, `password` | any app using SMTP |
| `vaultwarden-admin` | `vaultwarden-admin` | `ADMIN_TOKEN` | vaultwarden (via `existingSecret`) |

Add rows here as new secrets are introduced.

---

## 8. Verify the Setup

```bash
# Check ClusterSecretStore is ready
kubectl get clustersecretstore k8s-secrets

# Check an ExternalSecret synced successfully
kubectl get externalsecret -n cert-manager
kubectl describe externalsecret cloudflare-api-token -n cert-manager

# Confirm the target Secret was created by ESO
kubectl get secret cloudflare-api-token -n cert-manager

# Check ESO operator logs if something looks wrong
kubectl logs -n external-secrets deployment/external-secrets --tail=50
```

---

**Last Updated:** 2026-06-04
