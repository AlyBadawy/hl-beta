# Provisioning

Automated provisioning scripts for k3s cluster setup.

## Quick Start

```bash
./provision/provision.sh
```

This will interactively prompt for configuration values and save them to `config/secrets.yaml`.

## Scripts

### `config-secrets`

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

Validation and input functions are centralized in `provision/lib/validation.sh` for reuse across all provisioning scripts. These include:

- `validate_ip()` — IPv4 format validation
- `validate_domain()` — Domain name validation
- `validate_port()` — Port number validation (1-65535)
- `validate_email()` — Email address validation
- `prompt_with_validation()` — Interactive prompt with validation loop

See `provision/lib/validation.sh` for usage and documentation. Future provisioning scripts should source this file rather than recreating validation logic.
