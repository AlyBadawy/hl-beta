# TLS Certificate Architecture

How HTTPS certificates are issued, stored, and served across all cluster ingresses.

**Last Updated:** 2026-06-08  
**Applies to:** cert-manager v1.20, ingress-nginx (default IngressClass), single wildcard cert

---

## Overview

All hostnames under `*.in.alybadawy.com` share a **single wildcard TLS certificate** managed by cert-manager. The certificate covers:

- `*.in.alybadawy.com` (all subdomains: `grafana`, `argo`, `secrets`, `photos`, etc.)
- `in.alybadawy.com` (the apex domain)

TLS termination happens once at the ingress-nginx controller. Individual `Ingress` resources do **not** request, store, or reference any certificates.

---

## Components

### 1. ClusterIssuer — `letsencrypt-prod`

**File:** `k8s/components/cert-manager/cluster-issuer.yaml`

Configured for **DNS-01** challenge via Cloudflare. This is the only ACME solver type that can issue wildcard certificates — HTTP-01 cannot. The solver uses the `cloudflare-api-token` secret in the `networking` namespace (seeded by `provision/rebuild.sh` Step 7).

A `letsencrypt-staging` issuer is also present. Swap the `Certificate`'s `issuerRef.name` to `letsencrypt-staging` when testing to avoid Let's Encrypt rate limits.

### 2. Certificate — `wildcard-in-alybadawy-com`

**File:** `k8s/components/cert-manager/wildcard-certificate.yaml`  
**Namespace:** `networking`  
**Secret produced:** `wildcard-tls` (in the `networking` namespace)

cert-manager watches this resource, runs the DNS-01 challenge (creates a `_acme-challenge.in.alybadawy.com` TXT record via the Cloudflare API), and stores the resulting certificate and key in the `wildcard-tls` Secret. cert-manager automatically renews the cert before it expires (Let's Encrypt certs are valid for 90 days; renewal starts at 60 days).

### 3. ingress-nginx — `default-ssl-certificate`

**File:** `k8s/components/ingress-nginx/values.yaml`

```yaml
controller:
  extraArgs:
    default-ssl-certificate: networking/wildcard-tls
```

This tells the nginx controller to load `wildcard-tls` as the **global default certificate**. Any HTTPS request whose SNI hostname is not matched by a per-Ingress `tls[]` block (there are none) falls back to this cert — which is every request in this cluster.

---

## What Ingress Resources Look Like

Because TLS is handled globally at the controller level, Ingress resources are clean and minimal:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # No cert-manager.io/cluster-issuer annotation needed
spec:
  ingressClassName: nginx
  # No tls[] block needed
  rules:
    - host: myapp.in.alybadawy.com
      http:
        paths: ...
```

The `force-ssl-redirect: "true"` annotation is what triggers the HTTP→HTTPS redirect. It works unconditionally — it does not require a `tls[]` block on the Ingress.

---

## Adding a New Service

To expose a new service at `newapp.in.alybadawy.com`:

1. Create an `Ingress` resource with the host set to `newapp.in.alybadawy.com`.
2. Add the two redirect annotations (`ssl-redirect` and `force-ssl-redirect`).
3. **Do not** add a `tls[]` block.
4. **Do not** add `cert-manager.io/cluster-issuer` to the Ingress.
5. **Do not** create a separate `Certificate` resource.

The wildcard cert already covers `newapp.in.alybadawy.com` — no cert issuance or renewal work is needed.

---

## Certificate Lifecycle

```
cert-manager Certificate (networking ns)
    │
    ├─ watches → ClusterIssuer: letsencrypt-prod
    │               └─ DNS-01 solver → Cloudflare API → TXT record
    │
    └─ produces → Secret: wildcard-tls (networking ns)
                      │
                      └─ ingress-nginx loads at startup / on rotation
                             └─ serves to all vhosts as default cert
```

cert-manager rotates the cert automatically. When it writes an updated `wildcard-tls` Secret, ingress-nginx detects the change and hot-reloads — no downtime, no manual steps.

---

## Checking Certificate Status

```bash
# Current certificate status and expiry
kubectl get certificate wildcard-in-alybadawy-com -n networking
kubectl describe certificate wildcard-in-alybadawy-com -n networking

# View the issued cert's SANs and expiry date
kubectl get secret wildcard-tls -n networking -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text | grep -A2 "Subject Alternative\|Not After"

# Watch cert-manager reconcile (useful when waiting for initial issuance)
kubectl get certificaterequest -n networking -w
```

Expected `kubectl get certificate` output when healthy:
```
NAME                           READY   SECRET         AGE
wildcard-in-alybadawy-com      True    wildcard-tls   5d
```

`READY=False` means the cert is not yet issued or failed to renew — check `kubectl describe` for the reason and look at cert-manager logs:

```bash
kubectl logs -n networking -l app.kubernetes.io/name=cert-manager --tail=50
```

---

## What NOT To Do

| Action | Why it breaks things |
|---|---|
| Add `cert-manager.io/cluster-issuer` to an Ingress | cert-manager will try to create a new per-hostname `Certificate` and put its secret in the Ingress's namespace — redundant and wasteful |
| Add a `tls[]` block referencing a secret in another namespace | Kubernetes forbids cross-namespace Secret references in Ingress TLS — the Ingress will stay in a broken state |
| Add a `tls[]` block referencing a non-existent secret | nginx will serve a self-signed fallback cert for that host until the secret appears |
| Delete `wildcard-tls` from the `networking` namespace | nginx falls back to its self-signed default cert for all hosts until cert-manager re-issues |

---

## Staging / Testing

To test the issuance flow without hitting Let's Encrypt production rate limits:

1. In `wildcard-certificate.yaml`, change `issuerRef.name` to `letsencrypt-staging`.
2. Sync — cert-manager will issue a staging cert (trusted by your browser only after importing the staging CA).
3. Switch back to `letsencrypt-prod` when done.
