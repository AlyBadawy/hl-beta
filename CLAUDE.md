# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Project Structure

```
hl-beta/
├── config/                      # Configuration (git-ignored secrets)
│   ├── secrets.example.yaml     # Example secrets structure (tracked)
│   └── secrets.yaml             # Actual secrets (git-ignored, created by provision.sh)
├── provision/                   # Provisioning automation
│   ├── provision.sh             # Main orchestration script
│   ├── scripts/                 # Individual provisioning scripts
│   │   └── config-secrets       # Configuration collection & validation
│   ├── lib/                     # Helper functions & utilities (future)
│   └── README.md                # Provisioning documentation
├── docs/                        # Architecture and decision documentation
│   ├── 01-provisioning-architecture.md  # Phase 1 architecture overview
│   └── ADR-001-provisioning-script-design.md  # Design decisions & rationale
└── CLAUDE.md                    # This file

```

## Development Phases

### Phase 1: Configuration Management ✓ (Current)
**Status:** In Progress  
**What:** Interactive scripts for infrastructure configuration  
**Scripts:** `provision/scripts/config-secrets`  
**Output:** `config/secrets.yaml`

**Configuration includes:**
- Server IP and SSH credentials
- NAS storage location and mount path
- SMTP server (email notifications)
- Admin and notification emails
- Base domain for the cluster

### Phase 2: Server Bootstrap (In Progress)
**What:** Prepare the target Ubuntu server  
**Scripts:** Step 2, Step 3, Step 4, (TBD for remaining tasks)

**Completed Responsibilities:**
- ✓ SSH connectivity verification (Step 2: checks SSH access and NOPASSWD sudo)
- ✓ System updates and package installation (Step 3: apt update/upgrade + 23 essential packages)
- ✓ SWAP disabled (required for k3s)
- ✓ System information displayed and logged
- ✓ NAS mount setup (Step 4: mounts 4 NFS shares for homelab, backups, immich, nextcloud)

**Remaining Responsibilities:**
- Any additional network/storage configuration

### Phase 3: K3s Installation (Planned)
**What:** Install and configure k3s cluster  
**Scripts:** (TBD)
**Responsibilities:**
- K3s cluster initialization
- Node configuration
- Cluster health validation

### Phase 4: Application Deployment (Planned)
**What:** Deploy cluster infrastructure and applications  
**Scripts:** (TBD)
**Responsibilities:**
- Ingress and networking setup
- Storage class provisioning
- Application manifest deployment

## Key Design Decisions

See `docs/ADR-001-provisioning-script-design.md` for detailed rationale.

### 1. Configuration Collection
- **Interactive bash scripts** with sensible defaults
- **Input validation** (IP format, domain names, email format, port ranges)
- **Plain YAML storage** in `config/secrets.yaml` (not encrypted initially)

### 2. Security
- Secrets file created with mode 600 (read/write owner only)
- Never committed to git (.gitignore protection)
- Passwords entered with hidden input

### 3. Modularity
- Each script has a single responsibility
- Scripts called by `provision/provision.sh` orchestrator
- Configuration centralized for easy reference and updates

## Running the Provisioning

### Initial Setup
```bash
# Make scripts executable and run provisioning
./provision/provision.sh

# Result: Guided prompts create config/secrets.yaml
```

### Reviewing Configuration
```bash
cat config/secrets.yaml
```

### Updating Configuration
```bash
# Re-run and choose to reconfigure when prompted
./provision/provision.sh

# When prompted: Reconfigure secrets? [y/N]: 
# Type 'Y' to reconfigure all values
# Press Enter or 'N' to skip and keep existing configuration
```

On subsequent runs, the script will detect existing `config/secrets.yaml` and ask if you want to reconfigure. This allows for quick re-runs without redundant configuration prompts.

## Configuration Reference

See `config/secrets.example.yaml` for the structure. Key fields:

| Section | Field | Purpose | Default |
|---------|-------|---------|---------|
| server | ip | Target Ubuntu server IP | (required) |
| server | ssh_user | SSH user for remote access | homelab |
| nas | ip | NAS server IP | 172.20.20.2 |
| nas | base_share | NFS export path on NAS | /var/nfs/shared |
| nas | base_mount | Local mount point | /mnt/nas |
| smtp | server | Email server hostname | smtp.resend.com |
| smtp | port | SMTP port | 587 |
| smtp | username | SMTP auth username | (required) |
| smtp | password | SMTP auth password | (required) |
| smtp | from | Sender email address | (required) |
| email | admin | Admin notification email | (required) |
| domain | base | Base domain for cluster | in.alybadawy.com |

## Documentation

- **`provision/README.md`** — How to use the provisioning scripts
- **`docs/01-provisioning-architecture.md`** — Architecture and design philosophy
- **`docs/ADR-*.md`** — Architecture Decision Records with rationale

## Developer Notes

### When Adding New Configurations
1. Update the validation script (`provision/scripts/config-secrets`)
2. Add new fields to `config/secrets.example.yaml`
3. Document the field purpose and default in this CLAUDE.md
4. Update relevant ADR or create new one if it's a significant decision
5. Update `provision/README.md` if it changes how provisioning works

### Before Starting Phase 2
1. Review and confirm Phase 1 works as expected
2. Discuss Phase 2 scope with user
3. Create ADR-002 for Phase 2 decisions before implementation
4. Document Phase 2 architecture in `docs/02-server-bootstrap.md`

### Validation & Testing
Current approach:
- Input validation in the script (regex, ranges)
- Confirmation prompt before writing config
- No SSH/NAS connectivity checks yet (Phase 2 responsibility)

Future enhancements:
- Connection validation in Phase 2
- Dry-run mode for scripts
- Rollback capability

## Project Collaboration

**Important collaboration notes:**
- Discuss all architectural decisions before implementation
- Keep documentation updated with learnings and rationale
- Create ADRs when making significant design choices
- Explicitly ask questions when uncertain rather than assuming
- Document why decisions were made, not just how

---

**Last Updated:** 2026-05-29  
**Phase:** Configuration Management (Phase 1)
