# ADR-003: GitOps Ownership Handoff and ArgoCD Ingress Management

**Date:** 2026-05-30  
**Status:** Accepted  
**Deciders:** Aly Badawy

---

## Context

Phase 7 bootstrapped nginx-ingress and ArgoCD using `helm install` on the remote server, then handed control to ArgoCD via the root-app Application. This created two problems:

**Problem 1 — Dual Helm ownership:** ArgoCD manages resources via `helm template` + `kubectl apply`, not via `helm upgrade`. When the bootstrap uses `helm install`, it creates a Helm release tracking Secret in the cluster. This means two entities claim the same resources: the Helm CLI release AND ArgoCD. They use different values (bootstrap inline values vs git-ops values files), causing config drift and potential resource conflicts.

**Problem 2 — Inline values diverge from values files:** The original `nginx-ingress-app.yaml` and `argocd-app.yaml` had hardcoded inline `helm.values` blocks that differed from the actual `git-ops/nginx-ingress/values.yaml` and `git-ops/argocd/values.yaml` files. The values files were effectively dead config — only used during bootstrap, ignored by ArgoCD.

**Problem 3 — Duplicate ArgoCD Ingress:** The bootstrap created `argocd-server-ingress` via `kubectl apply` directly. Meanwhile, `argocd/values.yaml` had `ingress.enabled: true` with `{DOMAIN}` literal placeholder strings that were never substituted. The ArgoCD Application overrode this with `ingress.enabled: false` inline. The result was a manually-created ingress that ArgoCD had no knowledge of.

---

## Decision

### 1. Multi-source ArgoCD Applications

Both `nginx-ingress-app.yaml` and `argocd-app.yaml` in `root-app/templates/` now use ArgoCD's multi-source feature:

```yaml
sources:
  - repoURL: https://...        # upstream Helm chart registry
    chart: ingress-nginx
    targetRevision: 4.11.0
    helm:
      valueFiles:
        - $values/git-ops/nginx-ingress/values.yaml
  - repoURL: https://github.com/AlyBadawy/hl-beta
    targetRevision: main
    ref: values                 # provides $values context
```

The `ref: values` source is a "reference-only" source — it provides the git repo context so that `$values/...` paths resolve to files in this repo. This makes the values files in `git-ops/` the single source of truth for both bootstrap and GitOps management.

**Why multi-source over inline values:** Inline values duplicate configuration that already exists in `git-ops/` values files. With multi-source, changing a value in `values.yaml` is automatically picked up by ArgoCD on next sync — no need to edit the Application template too.

Multi-source was introduced in ArgoCD 2.6. The bootstrap uses ArgoCD chart 7.6.0 (ArgoCD 2.12.x), so this is fully supported.

### 2. Helm Tracking Secret Deletion for Ownership Handoff

After each `helm install` in the bootstrap, the Helm release tracking Secret is deleted:

```bash
kubectl delete secret \
  --namespace ingress-nginx \
  --selector "owner=helm,name=nginx-ingress" \
  --ignore-not-found
```

**Why this works:** The Helm tracking Secret (stored in the release namespace) is metadata that tells `helm ls` about a release. It has no effect on running pods or Kubernetes resources. Deleting it removes Helm CLI's claim on the resources without disrupting anything running. When ArgoCD then syncs and applies the Helm chart via `kubectl apply`, it takes sole ownership of those resources.

**Why not use `helm template | kubectl apply` in bootstrap instead:** The bootstrap already uses `helm install` and deleting the tracking secret is a two-line addition. Rewriting the bootstrap to use `helm template` + `kubectl apply` would require managing the rendered YAML, handling CRDs separately, and losing Helm's `--wait` and readiness checks.

**Idempotency:** Each bootstrap step now checks whether resources are already running before installing. If nginx-ingress or ArgoCD are already present (from a previous run or from ArgoCD management), the install step is skipped entirely.

### 3. ArgoCD Ingress as a Direct root-app Manifest

The ArgoCD Ingress is now defined as a plain Kubernetes manifest in `root-app/templates/argocd-ingress.yaml`, NOT through the ArgoCD Helm chart's `ingress.enabled` setting.

```yaml
# root-app/templates/argocd-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: {{ .Values.argocd.namespace }}
spec:
  ingressClassName: nginx
  rules:
    - host: "argo.{{ .Values.domain }}"
```

**Why not through the ArgoCD Helm chart:** The ArgoCD chart's ingress section requires passing the domain as a Helm parameter. This would require either hardcoding it in `argocd/values.yaml` (not template-friendly) or using `helm.parameters` overrides in the Application (fragile, scattered config). A direct manifest in root-app is simpler: it inherits the domain from `root-app/values.yaml` naturally via Helm templating.

**Lifecycle:** The ingress is owned by root-app. It is created when root-app first syncs (after bootstrap), updated if `root-app/values.yaml` domain changes, and deleted if the template is removed from git (with `prune: true`).

**Bootstrap ingress removal:** The bootstrap no longer creates the ArgoCD Ingress via `kubectl apply`. The old Step 4b has been removed. The manually-created ingress on already-provisioned servers will be adopted by ArgoCD (via `kubectl apply` of the same resource name), adding its ownership labels.

---

## Consequences

**Positive:**
- `git-ops/nginx-ingress/values.yaml` and `git-ops/argocd/values.yaml` are now the actual source of truth — no more divergence between bootstrap and ArgoCD values.
- No dual-ownership conflicts. ArgoCD is the sole manager of nginx-ingress and ArgoCD resources after bootstrap.
- ArgoCD Ingress domain is configured in one place (`root-app/values.yaml`) and flows through to the manifest automatically.
- Bootstrap is idempotent: re-running it safely skips already-running components.

**Negative / Trade-offs:**
- Multi-source Applications are slightly more complex to read than single-source. However, the `$values` ref pattern is idiomatic ArgoCD.
- After bootstrap, there is a brief window (until root-app syncs) where ArgoCD has no Ingress. Access via port-forward during this window. This is acceptable for a homelab.
- Helm tracking secrets being deleted means `helm ls` won't show nginx-ingress or argocd after bootstrap. This is intentional — ArgoCD is the management plane, not Helm CLI.

---

## Alternatives Considered

**Alt A: Rewrite bootstrap to use `helm template | kubectl apply`**  
Would eliminate Helm CLI tracking entirely. Rejected because it loses `--wait`, readiness checks, and Helm's rollback capability during bootstrap. The tracking secret deletion approach achieves the same ownership result with less change.

**Alt B: Keep inline values in ArgoCD Applications**  
Would mean maintaining two copies of every value (values file + inline). Rejected because it guarantees drift over time.

**Alt C: Manage ArgoCD Ingress through ArgoCD Helm chart (`ingress.enabled: true` + `helm.parameters`)**  
Would work but requires passing domain through parameters and keeping the values.yaml `{DOMAIN}` placeholder logic, which was previously broken. A direct root-app template is simpler and more explicit.
