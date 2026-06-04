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

## Secret 2 — `cluster-config`

| Field | Value |
|---|---|
| **Namespace** | `cluster-config` |
| **Type** | `Opaque` |
| **Keys** | `SMTP_USERNAME`, `SMTP_PASSWORD` |
| **Used by** | Any application that sends email via the cluster SMTP relay (`smtp.resend.com`) |
| **Created by** | `provision/scripts/configure-cluster` (prompts at runtime) |

**Create:**
```bash
kubectl create namespace cluster-config --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cluster-config \
  --namespace=cluster-config \
  --from-literal=SMTP_USERNAME="<YOUR_SMTP_USERNAME>" \
  --from-literal=SMTP_PASSWORD="<YOUR_SMTP_PASSWORD>" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Retrieve:**
```bash
# SMTP username
kubectl get secret cluster-config -n cluster-config \
  -o jsonpath="{.data.SMTP_USERNAME}" | base64 -d; echo

# SMTP password
kubectl get secret cluster-config -n cluster-config \
  -o jsonpath="{.data.SMTP_PASSWORD}" | base64 -d; echo
```

> This secret is created automatically when you run `provision/scripts/configure-cluster` (Phase 6 of provisioning).

---

## Secret 3 — `vaultwarden-admin`

| Field | Value |
|---|---|
| **Namespace** | `secrets` |
| **Type** | `Opaque` |
| **Key** | `ADMIN_TOKEN` |
| **Used by** | Vaultwarden — ESO reads this from the `secrets` namespace and distributes it to the `vaultwarden` namespace |
| **Created by** | Manually (bootstrap step — must exist before ArgoCD syncs the `vaultwarden` app) |

This secret must be seeded before the cluster syncs. Store the token value in a password manager (e.g., Vaultwarden itself, once it's running, or a local offline backup).

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
| `cluster-config` | `cluster-config` | `SMTP_USERNAME`, `SMTP_PASSWORD` | `configure-cluster` script (or manually) |
| `vaultwarden-admin` | `secrets` | `ADMIN_TOKEN` | Manually — must be done before first ArgoCD sync |

---

## Rebuild Order

Create secrets in this order to avoid dependency failures:

```
1. kubectl create namespace secrets
2. kubectl create secret generic vaultwarden-admin -n secrets ...
3. ./provision/provision-gitops.sh          # creates cloudflare-api-token, bootstraps ArgoCD
4. ./provision/scripts/configure-cluster   # creates cluster-config (SMTP)
```

Steps 3 and 4 prompt interactively for the values.

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
