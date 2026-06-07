# Secrets Rebuild Reference

This document lists every secret that must be manually created after a full cluster rebuild. All other secrets (TLS certificates, Helm-generated passwords, ESO-distributed copies) are created automatically once Vault is running and unsealed.

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
| **Namespace** | `networking` |
| **Type** | `Opaque` |
| **Key** | `api-token` |
| **Used by** | cert-manager `ClusterIssuer` (both `letsencrypt-prod` and `letsencrypt-staging`) for DNS-01 TLS challenges |
| **Created by** | `provision/bootstrap-argocd.sh` (prompts at runtime) |

The Cloudflare API token must have **Zone → DNS → Edit** permission for the `alybadawy.com` zone.

**Create:**
```bash
kubectl create namespace networking --dry-run=client -o yaml | kubectl apply -f -
kubectl -n networking create secret generic cloudflare-api-token \
  --from-literal=api-token="<YOUR_CLOUDFLARE_API_TOKEN>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Retrieve:**
```bash
kubectl get secret cloudflare-api-token -n networking \
  -o jsonpath="{.data.api-token}" | base64 -d; echo
```

---

## Secret 2 — `vault-unseal-key`

| Field | Value |
|---|---|
| **Namespace** | `security` |
| **Type** | `Opaque` |
| **Key** | `key` |
| **Used by** | `vault-auto-unseal` CronJob — unseals Vault within 60s of a reboot |
| **Created by** | Manually — must exist before ArgoCD syncs the `vault` app |

The unseal key is generated once during initial Vault initialization and must be stored offline. On a rebuild, it is seeded manually before Phase 8 so the CronJob can unseal the restored Vault automatically.

**Create:**
```bash
kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vault-unseal-key \
  --namespace=security \
  --from-literal=key="<UNSEAL_KEY_FROM_OFFLINE_BACKUP>" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Retrieve:**
```bash
kubectl get secret vault-unseal-key -n security \
  -o jsonpath="{.data.key}" | base64 -d; echo
```

---

## Summary Table

| Secret | Namespace | Keys | Who creates it |
|---|---|---|---|
| `cloudflare-api-token` | `networking` | `api-token` | `bootstrap-argocd.sh` (or manually) |
| `vault-unseal-key` | `security` | `key` | Manually — seeded from offline backup before Phase 5 |

---

## Offline Credentials Checklist

These values must be saved somewhere safe and **offline** (e.g., a local password manager, printed paper in a secure location). They cannot be recovered from the cluster alone after a rebuild:

- [ ] **Vault unseal key** — needed if the `vault-unseal-key` k8s Secret is ever lost. Without it, Vault will start sealed and all ESO-backed secrets will fail to sync.
- [ ] **Vault root token** — the bootstrap admin credential. Keep as a break-glass key after rotating to a non-root token.
- [ ] **Cloudflare API token** — needed to re-seed `cloudflare-api-token` if the cert-manager secret is lost.

---

## Rebuild Order

Create secrets in this order to avoid dependency failures:

```
1. ./provision/provision-server.sh              # Phases 2–6
2. kubectl create secret generic vault-unseal-key -n vault ...   ← from offline backup
3. ./provision/bootstrap-argocd.sh              # Phase 7: installs ArgoCD, seeds cloudflare-api-token
4. ./provision/restore-volumes.sh               # Phase 8: installs Longhorn, restores PVC backups
5. ./provision/activate-gitops.sh               # Phase 9: Vault (wave -1) starts → CronJob unseals → ESO syncs all secrets → apps start
```

On a rebuild, Vault's data volume is restored from its Longhorn backup — Vault is already initialized. Only the unseal key secret needs to be manually seeded.

---

## Auto-Generated Secrets (no action needed)

These are created automatically — do not create them manually:

| Secret | Namespace | Created by |
|---|---|---|
| `argocd-initial-admin-secret` | `argocd` | ArgoCD Helm chart |
| `prometheus-grafana` | `monitor` | kube-prometheus-stack Helm chart |
| `*-tls` (grafana, prometheus, alertmanager, whoami, argocd, vault) | various | cert-manager |
| `letsencrypt-*-account-key` | `cert-manager` | cert-manager |
| All app secrets (postgres, authentik, immich, etc.) | various | ESO (reads from Vault) |

---

**Last Updated:** 2026-06-06
