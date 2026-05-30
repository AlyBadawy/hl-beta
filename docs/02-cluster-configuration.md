# Cluster Configuration

## Overview

Phase 6 (Cluster Configuration Provisioning) creates Kubernetes ConfigMap and Secret resources in the `cluster-config` namespace. These resources contain cluster-wide configuration that applications can reference, following the 12-factor app principle of configuration separation.

## Resources Created

### Namespace: `cluster-config`

All cluster configuration resources are isolated in the `cluster-config` namespace to separate them from application workloads.

```bash
kubectl get all -n cluster-config
```

## ConfigMap: `cluster-config`

**Name:** `cluster-config`  
**Namespace:** `cluster-config`  
**Type:** Non-sensitive configuration data

The ConfigMap contains public cluster configuration that doesn't require security protection.

### Keys

| Key | Source | Purpose |
|-----|--------|---------|
| `BASE_DOMAIN` | `domain.base` in secrets.yaml | Base domain for the cluster (e.g., `in.alybadawy.com`) |
| `NAS_IP` | `nas.ip` in secrets.yaml | NAS server IP address |
| `NAS_BASE_SHARE` | `nas.base_share` in secrets.yaml | NFS export path on NAS (e.g., `/var/nfs/shared`) |
| `NAS_BASE_MOUNT` | `nas.base_mount` in secrets.yaml | Local mount point (e.g., `/mnt/nas`) |
| `NAS_HOMELAB_PATH` | Computed from `nas.base_mount` | Path to homelab data: `/mnt/nas/homelab` |
| `NAS_BACKUPS_PATH` | Computed from `nas.base_mount` | Path to backups: `/mnt/nas/backups` |
| `NAS_IMMICH_PATH` | Computed from `nas.base_mount` | Path to immich storage: `/mnt/nas/immich` |
| `NAS_NEXTCLOUD_PATH` | Computed from `nas.base_mount` | Path to nextcloud storage: `/mnt/nas/nextcloud` |
| `SMTP_SERVER` | `smtp.server` in secrets.yaml | SMTP server hostname (e.g., `smtp.resend.com`) |
| `SMTP_PORT` | `smtp.port` in secrets.yaml | SMTP port (e.g., `587`) |
| `SMTP_FROM` | `smtp.from` in secrets.yaml | Email sender address (e.g., `noreply@example.com`) |
| `ADMIN_EMAIL` | `email.admin` in secrets.yaml | Admin notification email |
| `SERVER_IP` | `server.ip` in secrets.yaml | Ubuntu server IP address |

### View ConfigMap

```bash
# View all keys and values
kubectl get configmap cluster-config -n cluster-config -o yaml

# View a specific key
kubectl get configmap cluster-config -n cluster-config -o jsonpath='{.data.BASE_DOMAIN}'
```

## Secret: `cluster-config`

**Name:** `cluster-config`  
**Namespace:** `cluster-config`  
**Type:** Sensitive credential data

The Secret contains SMTP credentials that should not be exposed in ConfigMaps or configuration files.

### Keys

| Key | Source | Purpose |
|-----|--------|---------|
| `SMTP_USERNAME` | `smtp.username` in secrets.yaml | SMTP authentication username |
| `SMTP_PASSWORD` | `smtp.password` in secrets.yaml | SMTP authentication password |

### View Secret

```bash
# View all keys (values are base64 encoded)
kubectl get secret cluster-config -n cluster-config -o yaml

# Decode a specific key value
kubectl get secret cluster-config -n cluster-config -o jsonpath='{.data.SMTP_PASSWORD}' | base64 -d

# View in human-readable form (shows decoded values)
kubectl get secret cluster-config -n cluster-config -o jsonpath='{.data}' | jq 'map_values(@base64d)'
```

## Usage in Kubernetes Manifests

### Environment Variables

Reference ConfigMap and Secret values as environment variables in Pod specifications:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example-app
  namespace: default
spec:
  containers:
  - name: app
    image: myapp:latest
    env:
      # Reference ConfigMap values
      - name: BASE_DOMAIN
        valueFrom:
          configMapKeyRef:
            name: cluster-config
            namespace: cluster-config
            key: BASE_DOMAIN

      - name: NAS_HOMELAB_PATH
        valueFrom:
          configMapKeyRef:
            name: cluster-config
            namespace: cluster-config
            key: NAS_HOMELAB_PATH

      - name: SMTP_SERVER
        valueFrom:
          configMapKeyRef:
            name: cluster-config
            namespace: cluster-config
            key: SMTP_SERVER

      # Reference Secret values
      - name: SMTP_USERNAME
        valueFrom:
          secretKeyRef:
            name: cluster-config
            namespace: cluster-config
            key: SMTP_USERNAME

      - name: SMTP_PASSWORD
        valueFrom:
          secretKeyRef:
            name: cluster-config
            namespace: cluster-config
            key: SMTP_PASSWORD
```

### Volume Mounts

Mount ConfigMap or Secret as a volume to inject configuration files:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example-app
spec:
  containers:
  - name: app
    image: myapp:latest
    volumeMounts:
    - name: cluster-config
      mountPath: /etc/cluster-config
      readOnly: true

  volumes:
  - name: cluster-config
    configMap:
      name: cluster-config
      namespace: cluster-config
      # Optional: mount specific keys as files
      items:
      - key: BASE_DOMAIN
        path: domain.txt
      - key: SMTP_SERVER
        path: smtp/server.txt
```

Files will be accessible at:
- `/etc/cluster-config/BASE_DOMAIN` (contains: `in.alybadawy.com`)
- `/etc/cluster-config/smtp/server.txt` (contains: `smtp.resend.com`)

### Deployment Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-example
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: example
  template:
    metadata:
      labels:
        app: example
    spec:
      containers:
      - name: app
        image: myapp:latest
        env:
        # ConfigMap references
        - name: BASE_DOMAIN
          valueFrom:
            configMapKeyRef:
              name: cluster-config
              namespace: cluster-config
              key: BASE_DOMAIN

        - name: NAS_IP
          valueFrom:
            configMapKeyRef:
              name: cluster-config
              namespace: cluster-config
              key: NAS_IP

        # Secret references
        - name: SMTP_PASSWORD
          valueFrom:
            secretKeyRef:
              name: cluster-config
              namespace: cluster-config
              key: SMTP_PASSWORD

        - name: SMTP_USERNAME
          valueFrom:
            secretKeyRef:
              name: cluster-config
              namespace: cluster-config
              key: SMTP_USERNAME
```

## Security Considerations

### ConfigMap

- **Not encrypted** — values are base64 encoded but not encrypted
- **Readable by anyone with cluster access** — suitable for non-sensitive configuration only
- **OK to commit to git** (if repository is restricted)

### Secret

- **Kubernetes native encryption** — secrets are encrypted at rest (if configured)
- **RBAC protected** — access can be restricted via role-based access control
- **Should NOT be committed to git** — keep `config/secrets.yaml` in `.gitignore`
- **Suitable for passwords, tokens, credentials**

### Best Practices

1. **Never put secrets in ConfigMap** — use Secret for SMTP password, API keys, tokens
2. **Use RBAC** — restrict Secret access to pods that need it
3. **Rotate credentials** — periodically update SMTP password and rebuild secrets
4. **Audit access** — log which pods access secrets (enable audit logging)
5. **Backup carefully** — secure backups of `config/secrets.yaml` offline

## Updating Configuration

To update cluster configuration:

1. **Edit `config/secrets.yaml`** on your local machine
2. **Re-run Phase 6**:
   ```bash
   ./provision/provision.sh
   # Reconfigure secrets? [y/N]: N
   # Phases 1-5 will skip
   # Phase 6 will run and update ConfigMap/Secret
   ```
3. **Redeploy applications** that reference the changed values

Or update manually:

```bash
# Update ConfigMap
kubectl patch configmap cluster-config -n cluster-config -p '{"data":{"BASE_DOMAIN":"new.domain.com"}}'

# Update Secret
kubectl patch secret cluster-config -n cluster-config -p '{"stringData":{"SMTP_PASSWORD":"newpassword"}}'
```

## Verification

After Phase 6 completes, verify resources were created:

```bash
# List all resources in cluster-config namespace
kubectl get all -n cluster-config

# Check ConfigMap exists and has data
kubectl describe configmap cluster-config -n cluster-config

# Check Secret exists
kubectl get secret cluster-config -n cluster-config

# Verify a ConfigMap value
kubectl get configmap cluster-config -n cluster-config -o jsonpath='{.data.BASE_DOMAIN}'
# Output: in.alybadawy.com

# Verify Secret exists (don't decode unless necessary)
kubectl get secret cluster-config -n cluster-config -o jsonpath='{.data}'
# Output: {"SMTP_PASSWORD":"c21...","SMTP_USERNAME":"dX..."}
```

## Troubleshooting

### ConfigMap/Secret Not Found

Verify the namespace:
```bash
kubectl get configmap,secret -n cluster-config
kubectl get configmap,secret -A | grep cluster-config
```

### Application Can't Access Values

Check environment variable references in Pod:
```bash
# Verify the ConfigMap/Secret name and keys match exactly
kubectl get configmap cluster-config -n cluster-config -o yaml | grep "^  [A-Z]"

# Check if Pod can mount/reference the resources
kubectl describe pod <pod-name> -n <namespace>
```

### Secret Values Not Available

If Secret is not accessible, check RBAC:
```bash
# Check if your ServiceAccount has permission to read secrets
kubectl get rolebinding,clusterrolebinding -A | grep secret
```

## Related Documentation

- **Phase 6:** `docs/01-provisioning-architecture.md` — Architecture and provisioning phases
- **Configuration:** `config/secrets.example.yaml` — Schema of configuration values
- **Provisioning:** `provision/README.md` — How to run provisioning scripts
- **Source Script:** `provision/scripts/configure-cluster` — Implementation details

