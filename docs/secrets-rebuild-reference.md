# Secrets Rebuild Reference

This document lists every secret that must be manually created after a full cluster rebuild. All other secrets (TLS certificates, Helm-generated passwords, ESO-distributed copies) are created automatically.

---

## How to Set and Retrieve a Secret

**Create / update a secret:**
```bash
kubectl create secret generic <name> \
  --namespace=<namespace> \
  --from-literal=<KEY>="<value>" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```
Using `--dry-run=client -o yaml | kubectl apply -f -` makes the command idempotent — safe to re-run to rotate a value.

**Retrieve and decode a secret key:**
```bash
kubectl get secret <name> -n <namespace> \
  -o jsonpath="{.data.<KEY>}" | base64 -d; echo
```

---

## Secret 1 — `cloudflare-api-token`

| Field | Value |
|---|---|
| **Namespace** | `cert-manager` |
| **Type** | `Opaque` |
| **Key** | `api-token` |
| **Used by** | cert-manager `ClusterIssuer` (both `letsencrypt-prod` and `letsencrypt-staging`) for DNS-01 TLS challenges |
| **Created by** | `provision/provision-gitops.sh` (prompts at runtime) |

The Cloudflare API token must have **Zone → DNS → Edit** permission for the `alybadawy.com` zone.

**Create:**
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace=cert-manager \
  --from-literal=api-token="<YOUR_CLOUDFLARE_API_TOKEN>" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Retrieve:**
```bash
kubectl get secret cloudflare-api-token -n cert-manager \
  -o jsonpath="{.data.api-token}" | base64 -d; echo
```

> This secret is created automatically when you run `provision/provision-gitops.sh`. You only need the command above if you are seeding it manually outside of the provisioning script.

---

## Secret 2 — `vaultwarden-admin`

| Field | Value |
|---|---|
| **Namespace** | `secrets` |
| **Type** | `Opaque` |
| **Key** | `ADMIN_TOKEN` |
| **Used by** | Vaultwarden — ESO reads this from the `secrets` namespace and distributes it to the `vaultwarden` namespace |
| **Created by** | Manually — must exist before ArgoCD syncs the `vaultwarden` app |

This is a pure bootstrap secret. It must be seeded before the cluster syncs. Store the token value offline (e.g., in your local password manager) since this is also what you'll use to log into Vaultwarden once it starts.

**Create:**
```bash
kubectl create namespace secrets --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vaultwarden-admin \
  --namespace=secrets \
  --from-literal=ADMIN_TOKEN="$(openssl rand -base64 48)" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

> Save the generated token before running — you cannot recover it without `kubectl` after this point.

**Retrieve:**
```bash
kubectl get secret vaultwarden-admin -n secrets \
  -o jsonpath="{.data.ADMIN_TOKEN}" | base64 -d; echo
```

---

## Summary Table

| Secret | Namespace | Keys | Who creates it |
|---|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `api-token` | `provision-gitops.sh` (or manually) |
| `vaultwarden-admin` | `secrets` | `ADMIN_TOKEN` | Manually — must be done before first ArgoCD sync |

---

## Offline Credentials Checklist

These values must be saved somewhere safe and **offline** (e.g., a local password manager, printed paper in a secure location). They cannot be recovered from the cluster alone after a rebuild:

- [ ] **Vaultwarden admin token** — the `ADMIN_TOKEN` used to access `/admin`. Stored in `secrets/vaultwarden-admin`.
- [ ] **Vaultwarden user master password** — the master password for your Vaultwarden user account (`alybadawy@icloud.com`). This is the key that unlocks the entire vault and all secrets stored inside it. Without it, all credentials in Vaultwarden are inaccessible even if the server is running.
- [ ] **Cloudflare API token** — needed to re-seed `cloudflare-api-token` if the cert-manager secret is lost.

> The Vaultwarden master password is never stored anywhere in the cluster — it exists only in your memory and your offline backup. Losing it means losing access to everything stored in the vault.

---

## Rebuild Order

Create secrets in this order to avoid dependency failures:

```
1. kubectl create namespace secrets
2. kubectl create secret generic vaultwarden-admin -n secrets ...   ← save the token offline
3. ./provision/provision-gitops.sh    # prompts for Cloudflare token, bootstraps ArgoCD
```

Once Vaultwarden is running, log in with your master password and resume storing credentials there. Future application secrets (SMTP, API keys, etc.) are added to Vaultwarden and seeded into the `secrets` namespace via `bw` CLI — see `docs/vaultwarden-secrets-management.md`.

---

## Auto-Generated Secrets (no action needed)

These are created automatically — do not create them manually:

| Secret | Namespace | Created by |
|---|---|---|
| `argocd-initial-admin-secret` | `argocd` | ArgoCD Helm chart |
| `prometheus-grafana` | `monitor` | kube-prometheus-stack Helm chart |
| `vaultwarden-admin` (copy) | `vaultwarden` | ESO (synced from `secrets` ns) |
| `*-tls` (grafana, prometheus, alertmanager, whoami, vaultwarden, argocd) | various | cert-manager |
| `letsencrypt-*-account-key` | `cert-manager` | cert-manager |

---

**Last Updated:** 2026-06-04
