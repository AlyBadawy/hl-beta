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

**Phase 2: Server Bootstrap** - In Progress
- ✓ SSH connectivity validation (Step 2: check-ssh-connection)
- ✓ System updates and dependencies (Step 3: update-dependencies)
- ✓ Configuration loader (config.sh library)
- ⏳ Network and storage configuration (planned)
- ⏳ NAS mount setup (planned)

### Completed: SSH Connectivity Check (Step 2)

Validates that the configured Ubuntu server is:
1. Reachable via SSH
2. Using the correct user
3. Configured with NOPASSWD sudo access

This ensures the server is ready for bootstrap provisioning.

### Completed: System Updates & Dependencies (Step 3)

Prepares the Ubuntu server with essential packages and configuration:
1. Runs `apt update` and `apt upgrade`
2. Installs 23 essential packages (curl, wget, git, jq, vim, nfs-common, apparmor, socat, etc.)
3. Disables SWAP (required for k3s operation)
4. Displays and logs system information (OS, kernel, CPU, memory, disk)
5. Logs all output to `provision.log` for debugging

User can skip this step if already installed.

## Future Phases

Phase 3: K3s installation (planned)
- SSH connectivity verification
- OS package updates and dependencies
- Network configuration
- Storage mount setup (NAS)

Phase 3: K3s installation (planned)
- k3s cluster initialization
- Node provisioning
- Cluster validation

Phase 4: Application deployment (planned)
- Networking setup
- Storage provisioning
- Application manifests

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
