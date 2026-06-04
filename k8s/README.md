# k3s GitOps platform (ArgoCD app-of-apps)

A self-managing GitOps setup for a [k3s](https://k3s.io) cluster. A single root
ArgoCD `Application` (the **app of apps**) installs and manages the whole
platform stack:

| Component | Purpose |
|---|---|
| **ArgoCD** | GitOps controller — *manages itself* after bootstrap |
| **ingress-nginx** | Ingress controller |
| **cert-manager** | TLS certificates via Let's Encrypt |
| **External Secrets Operator** | Sync secrets from external backends |
| **Vaultwarden** | Bitwarden-compatible password manager |

Every component is a Kustomize overlay that inflates the upstream Helm chart via
Kustomize's `helmCharts:` field — so the repo is "all Kustomize" while still
tracking official charts.

## How it works

```
scripts/bootstrap.sh
  │  kustomize build --enable-helm components/argocd | kubectl apply (server-side)
  ▼
ArgoCD running  ──apply──►  root/root-app.yaml  (the "app of apps")
                                   │  watches apps/, creates one child app each
                                   ▼
   ┌──────────┬─────────────┬──────────────┬──────────────────┬───────────┬─────────┐
 root-self  ingress-nginx  cert-manager  external-secrets   vaultwarden  argocd
 (wave 0)     (wave 0)       (wave 0)       (wave 0)          (wave 2)   (wave 0)
     │                                                                      │
 tracks root/ — the same                            tracks components/argocd — the
 root-app.yaml that was                             same chart used to bootstrap, so
 applied imperatively, so                           ArgoCD ADOPTS itself with no diff
 the ROOT app ADOPTS itself                         ► from here on, ArgoCD is GitOps.
 ► the root app is now GitOps too.
```

```
.
├── scripts/
│   ├── bootstrap.sh        # install ArgoCD, apply root app, hand off ownership
│   └── set-repo-url.sh     # replace the placeholder repoURL across manifests
├── root/root-app.yaml      # the app-of-apps Application -> apps/
├── apps/                   # one ArgoCD Application per component (synced by root)
│   └── root.yaml           #   ...incl. "root-self", which tracks root/ so the
│                           #      root app manages ITSELF
└── components/             # the real Kustomize+Helm definition for each component
```

- **`components/<name>/`** — the actual software definition (`kustomization.yaml`
  with a `helmCharts:` entry + `values.yaml`).
- **`apps/<name>.yaml`** — a thin `Application` pointing at `components/<name>`.
- **`root/root-app.yaml`** — recurses `apps/` and creates every child app.

### Self-management
Two layers manage themselves after bootstrap:

- **ArgoCD** — `components/argocd` is used by **both** `bootstrap.sh` (initial
  imperative install) **and** `apps/argocd.yaml` (the Application). Because they
  render identical manifests, the first sync adopts the running ArgoCD with no
  changes. Upgrading ArgoCD afterward is just a version bump in
  `components/argocd/kustomization.yaml` + `git push`.
- **The root app** — `root/root-app.yaml` is applied imperatively by
  `bootstrap.sh`, and `apps/root.yaml` (the `root-self` Application) tracks the
  `root/` directory. On first sync it adopts the running root Application with no
  diff, so the root app becomes GitOps-managed too. Changing the root app — its
  watched path, sync policy, revision, etc. — is now just an edit to
  `root/root-app.yaml` + `git push`; no re-running `bootstrap.sh`.

Both are the same trick: render in Git exactly what was applied imperatively, so
the first sync is a no-op adoption.

### Sync ordering
Child apps use `argocd.argoproj.io/sync-wave` annotations: controllers
(ingress-nginx, cert-manager, external-secrets, argocd) in **wave 0**, the
cert-manager `ClusterIssuer` in **wave 1** (after its CRDs), and Vaultwarden in
**wave 2** (after the ingress controller + issuer exist). All apps sync with
`ServerSideApply=true`, which is required for the large cert-manager / ESO CRDs.

## Prerequisites

- **k3s with Traefik disabled** so nginx-ingress is the only ingress controller.
  - New install:
    ```bash
    curl -sfL https://get.k3s.io | sh -s - --disable=traefik --disable=servicelb=false
    ```
    (or add `disable: [traefik]` to `/etc/rancher/k3s/config.yaml`).
  - Existing cluster: disable Traefik via a `HelmChartConfig`/`--disable=traefik`
    and remove the Traefik resources, then let nginx take over `:80/:443`.
- A workstation with **`kubectl`**, **`kustomize` ≥ 5**, and **`helm`** on `PATH`
  (Kustomize shells out to `helm` for `--enable-helm`), and a `KUBECONFIG`
  pointing at the cluster.
- A Git repo hosting this directory that the cluster can reach.
- DNS records for your ArgoCD and Vaultwarden hostnames pointing at the node /
  load-balancer IP (needed for Let's Encrypt HTTP-01 validation).

## Usage

1. **Point the manifests at your repo:**
   ```bash
   ./scripts/set-repo-url.sh https://github.com/you/k8s.git main
   ```
2. **Fill in the placeholders** (search the repo for `PLACEHOLDER` /
   `example.com` / `CHANGE_ME`):
   - `components/argocd/values.yaml` — `argocd.example.com`
   - `components/cert-manager/cluster-issuer.yaml` — Let's Encrypt email
   - `components/vaultwarden/values.yaml` — `vault.example.com` + admin token
3. **Commit and push** (ArgoCD reads the child apps from Git):
   ```bash
   git add -A && git commit -m "Configure platform" && git push
   ```
4. **Bootstrap:**
   ```bash
   REPO_URL=https://github.com/you/k8s.git ./scripts/bootstrap.sh
   ```
5. **Log in** with the initial admin password the script prints, then rotate it
   and delete `argocd-initial-admin-secret`.

## Adding another app

1. Create `components/<name>/kustomization.yaml` (+ `values.yaml`).
2. Add `apps/<name>.yaml` (copy an existing one, adjust name/path/namespace/wave).
3. `git push` — the root app picks it up automatically.

## Validate locally (no cluster)

```bash
# Every component renders:
for d in components/*/; do
  kustomize build --enable-helm "$d" >/dev/null && echo "OK $d"
done

# Application/manifest YAML is well-formed:
kubectl apply --dry-run=client -f apps/ -f root/
```

## Notes

- Chart versions are pinned in each `components/*/kustomization.yaml`; bump and
  push to upgrade. Verify the latest stable before first bootstrap.
- The Vaultwarden chart ships a **public** example admin-token hash — you must
  replace it. Ideally manage it through External Secrets once you've configured a
  backend (Vault, AWS SSM, GCP SM, …) via a `SecretStore`/`ClusterSecretStore`.
- While testing TLS, switch the `cert-manager.io/cluster-issuer` annotations to
  `letsencrypt-staging` to avoid Let's Encrypt production rate limits.
