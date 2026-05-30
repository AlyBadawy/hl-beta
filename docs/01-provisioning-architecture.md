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

## Future Phases

Phase 1 (Current): Configuration management
- ✓ Secrets collection
- ✓ Input validation
- ✓ Example configuration

Phase 2: Server bootstrap (planned)
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
