# Provisioning Architecture

## Overview

The provisioning system is a modular approach to bootstrapping a k3s cluster on Ubuntu 26.04. It separates configuration collection from infrastructure provisioning, allowing for flexibility and repeatability.

## Structure

```
provision/
├── provision.sh          # Main orchestration script
├── scripts/
│   └── config-secrets    # Configuration collection with validation
└── lib/                  # Helper functions and utilities (future)
```

## Design Principles

### 1. **Separation of Concerns**
- Configuration is collected once and stored centrally in `config/secrets.yaml`
- Actual provisioning scripts will consume this configuration independently
- Allows each script to focus on a single responsibility

### 2. **Interactive Configuration**
- Users provide configuration through guided prompts
- Sensible defaults reduce typing and errors
- Input validation prevents invalid configurations early

### 3. **Validation Before Persistence**
- All inputs are validated (IP format, domain names, email addresses, port ranges)
- Confirmation step before writing to disk
- Prevents invalid configuration from being saved

### 4. **Security by Default**
- Secrets file is created with restrictive permissions (mode 600)
- Passwords entered with hidden input (no echo)
- Secrets file is git-ignored to prevent accidental commits
- Clear example file shows structure without exposing secrets

## Configuration Flow

```
User Input
    ↓
[Validation]
    ↓
[Summary & Confirmation]
    ↓
[Save to config/secrets.yaml]
```

## Implementation Status

**Phase 1: Configuration Management** ✓ Complete
- ✓ Secrets collection (config-secrets script)
- ✓ Input validation (validation.sh library)
- ✓ Example configuration (secrets.example.yaml)
- ✓ Skip existing secrets on re-run (provision.sh)

**Phase 2: Server Bootstrap** - Complete
- ✓ SSH connectivity validation (Step 2: check-ssh-connection)
- ✓ System updates and dependencies (Step 3: update-dependencies)
- ✓ NAS mount setup (Step 4: mount-nas)
- ✓ Configuration loader (config.sh library)

**Phase 3: K3s Installation** - Complete
- ✓ K3s cluster installation (Step 5: install-k3s)

### Completed: SSH Connectivity Check (Phase 2)

Validates that the configured Ubuntu server is:
1. Reachable via SSH
2. Using the correct user
3. Configured with NOPASSWD sudo access

This ensures the server is ready for bootstrap provisioning.

### Completed: System Updates & Dependencies (Phase 3)

Prepares the Ubuntu server with essential packages and configuration:
1. Runs `apt update` and `apt upgrade`
2. Installs 23 essential packages (curl, wget, git, jq, vim, nfs-common, apparmor, socat, etc.)
3. Disables SWAP (required for k3s operation)
4. Displays and logs system information (OS, kernel, CPU, memory, disk)
5. Logs all output to `provision.log` for debugging

User can skip this step if already installed.

### Completed: NAS Storage Mounting (Phase 4)

Configures NFS mounts for persistent storage:
1. Tests NAS connectivity (verifies NAS is reachable)
2. Creates mount directories (`/mnt/nas/homelab`, `/mnt/nas/backups`, `/mnt/nas/immich`, `/mnt/nas/nextcloud`)
3. Adds NFS entries to `/etc/fstab` (checks for duplicates to avoid re-adding on re-run)
4. Backs up `/etc/fstab` before modifications (with timestamp)
5. Mounts all NFS filesystems immediately
6. Displays mount status and disk usage
7. Logs all output to `provision.log`

Mount points are safe for kubernetes deployments with optimized NFS options (automount, nofail, network timeout).

### Completed: K3s Cluster Installation (Phase 5)

Installs and validates a single-node k3s kubernetes cluster:
1. Checks if k3s is already installed (safe to re-run)
2. Installs k3s v1.36.1+k3s1 if needed (with traefik disabled)
3. Waits for k3s service to start (up to 1 minute with retries)
4. Verifies cluster readiness (kubectl connectivity, node status, coredns)
5. Displays cluster information and kubeconfig location
6. Logs all output to `provision.log`

**Configuration Notes:**
- Traefik ingress controller is disabled (install your own ingress later)
- Single-node cluster (control plane + worker on same node)
- Ready for application deployment after this step
- Kubeconfig available at `/etc/rancher/k3s/k3s.yaml` on server

### Completed: Cluster Configuration Provisioning (Phase 6)

Provisions cluster-wide configuration from `config/secrets.yaml` as Kubernetes ConfigMap and Secret:
1. Creates `cluster-config` namespace
2. Creates `cluster-config` ConfigMap with non-sensitive data (domain, NAS paths, SMTP server, email addresses, server IP)
3. Creates `cluster-config` Secret with sensitive credentials (SMTP username and password)
4. Verifies resources are created and accessible

**Purpose:** Decouples configuration from application manifests, allowing applications to reference cluster configuration via environment variables or volume mounts. Follows 12-factor app principles.

**Usage in Kubernetes:**
```yaml
env:
  - name: BASE_DOMAIN
    valueFrom:
      configMapKeyRef:
        name: cluster-config
        key: BASE_DOMAIN
  - name: SMTP_PASSWORD
    valueFrom:
      secretKeyRef:
        name: cluster-config
        key: SMTP_PASSWORD
```

## Implementation Status Summary

| Phase | Status | Description |
|-------|--------|-------------|
| Phase 1 | ✓ Complete | Configuration collection (secrets.yaml) |
| Phase 2 | ✓ Complete | SSH connectivity check and validation |
| Phase 3 | ✓ Complete | System updates and package installation |
| Phase 4 | ✓ Complete | NAS storage mounting and verification |
| Phase 5 | ✓ Complete | K3s cluster installation and verification |
| Phase 6 | ✓ Complete | Cluster configuration provisioning (ConfigMap, Secret) |
| Phase 7 | Planned | Application deployment (ingress, storage classes, manifests) |

## Future Phases

**Phase 7: Application Deployment** (planned)
- Ingress controller setup and configuration
- Storage class provisioning for NAS mounts
- Application manifest deployment
- Service networking and DNS configuration

## Configuration Schema

See `config/secrets.example.yaml` for the full schema. Key sections:

- **server**: Target server IP and SSH credentials
- **nas**: Network storage configuration for persistent data
- **smtp**: Email service for notifications and alerts
- **email**: Email addresses for notifications
- **domain**: Base domain for the cluster (used for ingress, DNS, etc.)

## Validation Rules

| Field | Validation | Example |
|-------|-----------|---------|
| Server IP | Valid IPv4 format | 192.168.1.100 |
| Domain | Valid DNS domain | in.alybadawy.com |
| SMTP Port | 1-65535 | 587 |
| Email | Valid email format | admin@example.com |

## Running the Provisioning

```bash
# Interactive mode (guided)
./provision/provision.sh

# Result: config/secrets.yaml created with all configuration
```

## Next Steps

1. Once configured, refer to Phase 2 implementation for server bootstrap
2. Configuration can be updated by re-running the script (it will overwrite)
3. Keep a backup of `config/secrets.yaml` if you have critical values
