# Provisioning

Automated provisioning scripts for k3s cluster setup.

## Quick Start

```bash
./provision/provision.sh
```

This will interactively prompt for configuration values and save them to `config/secrets.yaml`.

### First Run
On first run, all configuration values will be prompted for.

### Subsequent Runs
If `config/secrets.yaml` already exists, you'll be prompted:
```
✓ Existing configuration found at config/secrets.yaml

Reconfigure secrets? [y/N]: 
```
- Press `Enter` or type `N` to skip and proceed to Step 2
- Type `Y` to reconfigure all secrets (overwrites existing values)

## Provisioning Steps

## Provisioning Phases

### Phase 1: `config-secrets`

Collects and validates configuration for:
- Server IP and SSH credentials
- NAS storage details
- SMTP server configuration
- Admin and user emails
- Base domain

**Features:**
- Interactive prompts with sensible defaults
- Input validation (IP format, domain names, email addresses, ports)
- Saves configuration to `config/secrets.yaml` with restricted permissions (600)
- Example file available: `config/secrets.example.yaml`

### Phase 2: `check-ssh-connection`

Validates SSH connectivity and permissions to the target server.

**What it checks:**
1. SSH connectivity using configured server IP and SSH user
2. Verifies SSH user identity (`whoami` matches configured user)
3. Validates NOPASSWD sudo access (`sudo whoami` returns "root")

**Features:**
- 5 second timeout per SSH command (quick failure detection)
- Detailed error messages if validation fails
- Exits with error status if any check fails (prevents bad configurations)
- Uses key-based authentication (assumes SSH keys are configured)

**Requirements:**
- SSH key-based authentication configured for the server
- `ssh_user` must have passwordless sudo access (NOPASSWD in sudoers)

### Phase 3: `update-dependencies`

Updates the system and installs essential packages for k3s provisioning.

**What it does:**
1. Asks user to confirm (Y/n, Y is default)
2. Runs `apt update` and `apt upgrade`
3. Installs 23 essential packages (curl, wget, git, jq, vim, nfs-common, apparmor, socat, etc.)
4. Disables SWAP (required for k3s)
5. Displays system information (OS, kernel, CPU, memory, disk usage)

**Features:**
- Continues on package installation failure (skips failed packages)
- Logs all output to `provision.log` in project root
- Can skip this step if user chooses (N when prompted)
- Remote execution via SSH (updates happen on target server)
- Detailed error reporting for failed commands

**Log Output:**
All steps are logged to `provision.log` for future reference and debugging.

### Phase 4: `mount-nas`

Sets up NFS mounts for the NAS storage on the server.

**What it does:**
1. Tests NAS connectivity (verifies NAS IP is reachable)
2. Creates mount directories: `/mnt/nas/homelab`, `/mnt/nas/backups`, `/mnt/nas/immich`, `/mnt/nas/nextcloud`
3. Adds NFS entries to `/etc/fstab` (checks for duplicates, won't re-add existing entries)
4. Backs up `/etc/fstab` before modifications
5. Mounts all NFS filesystems immediately
6. Displays current mount status and disk usage

**Features:**
- Checks for duplicate fstab entries (safe to run multiple times)
- Creates /etc/fstab.backup with timestamp before changes
- Verifies mounts succeeded
- NFS mount options optimized for kubernetes (automount, nofail, etc.)
- Logs all output to `provision.log`
- Remote execution via SSH

**NFS Mount Options:**
```
defaults,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=10
```
- `_netdev`: network filesystem (waits for network before mounting)
- `nofail`: don't block boot if mount fails
- `x-systemd.automount`: auto-mount on access

### Phase 5: `install-k3s`

Installs and verifies k3s kubernetes cluster on the server.

**What it does:**
1. Checks if k3s is already installed (skips installation if present)
2. Downloads and installs k3s v1.36.1+k3s1 in single-node mode
3. Waits for k3s service to start (up to 1 minute)
4. Verifies cluster readiness:
   - kubectl connectivity
   - Node status (should be Ready)
   - CoreDNS pod deployment
5. **Copies kubeconfig locally** to `~/.kube/config`
6. **Updates shell profiles** (~/.bashrc, ~/.zshrc) with KUBECONFIG export
7. **Exports KUBECONFIG** for current session
8. Displays k3s version and cluster information

**Features:**
- Detects existing k3s installation and skips reinstall
- Automatic retry logic (waits up to 1 minute for service to start)
- Comprehensive readiness checks
- Shows kubeconfig path for local kubectl access
- Provides next steps for deploying applications
- Logs all output to `provision.log`
- Remote execution via SSH

**Kubeconfig Access:**
After installation, copy kubeconfig for local access:
```bash
scp homelab@$SERVER_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/config
```

**K3s Configuration:**
- Version: v1.36.1+k3s1 (latest stable)
- Traefik disabled: You'll manage your own ingress controller later
- Single-node mode: Control plane + worker on same node

**Environment Variables:**
```bash
K3S_VERSION="v1.36.1+k3s1"
K3S_INSTALL_SCRIPT="https://get.k3s.io"
K3S_INSTALL_EXEC="--disable=traefik"
```

### Phase 6: `configure-cluster`

Provisions cluster configuration from `config/secrets.yaml` as Kubernetes ConfigMap and Secret.

**What it does:**
1. Creates `cluster-config` namespace
2. Creates `cluster-config` ConfigMap with non-sensitive cluster data:
   - Base domain
   - NAS IP, mount paths, and share paths
   - SMTP server, port, and from address
   - Admin email
   - Server IP
3. Creates `cluster-config` Secret with sensitive credentials:
   - SMTP username and password
4. Verifies both ConfigMap and Secret are created successfully

**Features:**
- Loads all configuration from `config/secrets.yaml` using config loaders
- Splits configuration between ConfigMap (public) and Secret (sensitive passwords)
- Safe to re-run (uses `kubectl apply` for idempotent updates)
- Displays ConfigMap and Secret keys for verification
- Logs all output to `provision.log`
- Remote execution via SSH

**Usage in Kubernetes Manifests:**

Reference ConfigMap values as environment variables:
```yaml
env:
  - name: BASE_DOMAIN
    valueFrom:
      configMapKeyRef:
        name: cluster-config
        key: BASE_DOMAIN
```

Reference Secret values:
```yaml
env:
  - name: SMTP_PASSWORD
    valueFrom:
      secretKeyRef:
        name: cluster-config
        key: SMTP_PASSWORD
```

**Verification:**
```bash
# View ConfigMap
kubectl get configmap cluster-config -n cluster-config -o yaml

# View Secret keys (values are base64 encoded)
kubectl get secret cluster-config -n cluster-config -o yaml
```

## Configuration

All configuration is stored in `config/secrets.yaml` (gitignored). See `config/secrets.example.yaml` for the structure.

### Server Configuration

- `server.ip`: IP address of the Ubuntu server to provision
- `server.ssh_user`: SSH user for remote access (defaults to `homelab`)

### NAS Configuration

- `nas.ip`: NAS server IP (defaults to 172.20.20.2)
- `nas.base_share`: Base NFS export path (defaults to /var/nfs/shared)
- `nas.base_mount`: Where to mount NAS locally (defaults to /mnt/nas)

### SMTP Configuration

Required for cluster notifications and alerts.

- `smtp.server`: SMTP server hostname (defaults to smtp.resend.com)
- `smtp.port`: SMTP port (defaults to 587)
- `smtp.username`: SMTP authentication username
- `smtp.password`: SMTP authentication password
- `smtp.from`: Email address used for sending notifications

### Email Configuration

- `email.admin`: Admin email for alerts and notifications

### Domain Configuration

- `domain.base`: Base domain for the cluster (defaults to in.alybadawy.com)

## Security

- `config/secrets.yaml` is git-ignored and should never be committed
- The secrets file is created with restrictive permissions (mode 600)
- Passwords are entered without echo (hidden input)

## Helper Functions

### `lib/validation.sh`

Validation and input functions for collecting user configuration:

- `validate_ip()` — IPv4 format validation
- `validate_domain()` — Domain name validation
- `validate_port()` — Port number validation (1-65535)
- `validate_email()` — Email address validation
- `prompt_with_validation()` — Interactive prompt with validation loop

See `provision/lib/validation.sh` for usage and documentation.

### `lib/config.sh`

Configuration loader for reading secrets.yaml:

- `get_config_value(file, section, key)` — Get a single config value
- `load_ssh_config(file)` — Load SSH configuration (sets SSH_USER, SERVER_IP)
- `load_smtp_config(file)` — Load SMTP configuration
- `load_nas_config(file)` — Load NAS configuration

See `provision/lib/config.sh` for usage and documentation.

**Future scripts should source these files** rather than recreating validation or config-loading logic. Keep helper functions centralized in `lib/` for consistency across all provisioning phases.
