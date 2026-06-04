# GitOps - App of Apps Architecture

This directory contains the App of Apps pattern implementation for the k3s cluster. The root application manages all other applications in the cluster.

## Structure

```
git-ops/
├── root-app/                     # Root Application (App of Apps)
│   ├── Chart.yaml               # Helm chart metadata
│   ├── values.yaml              # Default values
│   └── templates/               # Kubernetes manifests
│       ├── argocd-app.yaml     # Self-managing ArgoCD
│       ├── nginx-ingress-app.yaml # Nginx Ingress Controller
│       └── git-config-cm.yaml  # Git repository configuration
├── argocd/                       # ArgoCD Helm values
│   ├── Chart.yaml
│   └── values.yaml              # ArgoCD-specific configuration
├── nginx-ingress/                # Nginx-ingress Helm values
│   ├── Chart.yaml
│   └── values.yaml              # Nginx-specific configuration
└── README.md                     # This file
```

## App of Apps Pattern

The root application (root-app) is a Helm chart that defines child applications:

1. **argocd-app.yaml** — ArgoCD manages itself (self-referential)
2. **nginx-ingress-app.yaml** — Nginx Ingress Controller
3. **git-config-cm.yaml** — ConfigMap with git repository URL

When the bootstrap Application is created, ArgoCD syncs the root-app, which then creates and manages all child applications.

## Bootstrap Process

Phase 7 executes the following:
1. Installs nginx-ingress controller (prerequisite for Argo UI ingress)
2. Creates argocd namespace
3. Applies bootstrap Application manifest pointing to `git-ops/root-app`
4. Waits for ArgoCD to become ready
5. Displays Argo UI access instructions

After bootstrap:
- ArgoCD manages itself and all cluster applications
- Git (main branch) is source of truth
- Changes in git-ops/ are automatically synced to cluster

## Accessing ArgoCD

Once Phase 7 completes:

```bash
# Get initial admin password
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port-forward if ingress is not ready
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Visit: https://argo.in.alybadawy.com (or http:// until SSL is configured)
```

## Configuration

### Git Repository

Repository URL is stored in ConfigMap `git-config` in `cluster-config` namespace:
- **Key:** `GIT_REPO_URL`
- **Value:** `https://github.com/AlyBadawy/hl-beta`
- **Branch:** main

### ArgoCD Storage

Currently using local ephemeral storage (lost on pod restart). When Longhorn is installed, update the StorageClass reference in `argocd/values.yaml`.

### Nginx-Ingress

Nginx-Ingress is deployed to manage ingress for ArgoCD and future applications.
- **Namespace:** ingress-nginx
- **Service Type:** LoadBalancer (if available) or NodePort

## Adding New Applications

To add a new application:

1. Create a new chart folder in `git-ops/`
2. Create an Application manifest in `git-ops/root-app/templates/`
3. Reference it in the root-app Application sync
4. Commit to git (main branch)
5. ArgoCD will automatically sync

Example Application manifest:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: {{ .Values.gitRepoUrl }}
    targetRevision: main
    path: git-ops/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Future Considerations

- **Longhorn:** Replace ephemeral ArgoCD storage with Longhorn PVCs
- **Vaultwarden:** Manage secrets with Vaultwarden instead of git-committed values
- **SSL/TLS:** Configure cert-manager and Let's Encrypt for HTTPS
- **RBAC:** Implement fine-grained access control for applications

## Troubleshooting

### ArgoCD pod not starting

Check logs:
```bash
kubectl logs -n argocd deployment/argocd-server -f
```

### Applications not syncing

Check Application status:
```bash
kubectl get applications -n argocd
kubectl describe app root-app -n argocd
```

### Git sync issues

Verify git repo URL in ConfigMap:
```bash
kubectl get cm git-config -n cluster-config -o yaml
```

## Related Documentation

- **Phase 6:** `docs/02-cluster-configuration.md` — Cluster configuration (ConfigMaps, Secrets)
- **Phase 7:** `provision/README.md` — Provisioning script documentation
- **Architecture:** `docs/01-provisioning-architecture.md` — Overall provisioning architecture

