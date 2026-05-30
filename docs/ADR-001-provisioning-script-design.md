# ADR-001: Provisioning Script Design

**Status:** Accepted  
**Date:** 2026-05-29  
**Context:** Building k3s cluster provisioning automation

## Decision

Use interactive bash scripts for configuration collection with:
1. **Interactive-only mode** (no env var fallback yet)
2. **Input validation** with regex patterns for IPs, domains, emails, ports
3. **Plain YAML secrets** storage (not encrypted initially)
4. **Central configuration** in `config/secrets.yaml` consumed by downstream scripts

## Rationale

### Interactive-Only (Why not env vars?)
- **Chosen:** Interactive prompts only
- **Reason:** Cluster setup is typically one-time per homelab. Removing env var support keeps the script simple and prevents accidental secrets in CI/CD configs at this stage.
- **Tradeoff:** Harder to automate later, but we can add env var support in future without breaking existing behavior
- **Future:** Phase 2+ scripts can support CI/CD if needed by exporting from config/secrets.yaml

### Input Validation (Why validate?)
- **Chosen:** Validate IPs, domains, emails, port numbers
- **Reason:** Invalid configuration discovered at runtime is costly (failed deployments, wasted time). Catching mistakes interactively is faster than debugging production issues.
- **Validation approach:** Regex patterns for format, numeric range checks for ports
- **Note:** Does NOT validate SSH connectivity or NAS reachability—those are Phase 2 responsibilities

### Plain YAML Secrets (Why not encrypted?)
- **Chosen:** Store secrets in plain YAML initially
- **Reason:** 
  - Encryption adds tooling complexity (sops, sealed-secrets, etc.)
  - Single-user homelab doesn't require encryption if file permissions are correct
  - Git ignore + file permissions (600) are sufficient for initial phases
  - Can migrate to encrypted storage (sops/sealed-secrets) later without changing script interface
- **Protection:** File created with mode 600, never git-committed via .gitignore
- **Future:** Phase 3/4 can integrate encrypted secrets (sops) if cluster scales

### Centralized Configuration (Why one secrets file?)
- **Chosen:** Single `config/secrets.yaml` as source of truth
- **Reason:**
  - Avoids duplicating config across scripts
  - Single backup/recovery point
  - Scripts can independently load values as needed
  - Easier to audit what was configured
- **Alternatives considered:** Env vars (lost on restart), encrypted K8s secrets (requires cluster), separate per-script configs (duplication)

## Consequences

### Positive
✓ Simple, readable bash code  
✓ Quick feedback loop (interactive validation)  
✓ No external dependencies (pure bash)  
✓ Secrets protected by OS file permissions  
✓ Easy to extend with new config values  
✓ Clear example file for documentation  

### Negative
✗ Can't easily automate in CI/CD (yet)  
✗ No encryption at rest (acceptable for Phase 1)  
✗ Manual config updates if credentials rotate  
✗ Passwords appear in bash process list briefly during input (mitigated by hidden input)  

## Implementation Details

- **Validation regex patterns:** Standard IP, domain, email patterns from RFC (simplified)
- **File permissions:** Created with `chmod 600` (read/write owner only)
- **Passwords:** Input with `read -s` to hide from terminal display
- **Defaults:** Provided for 6 of 11 configuration values (sensible cluster defaults)

## Migration Path

If encryption becomes needed:
1. Introduce `phase-2-encrypt-secrets` script
2. Convert plain YAML to sops-encrypted format
3. Downstream scripts check for encrypted format, decrypt on load
4. No change to this script's interface

## Alternative Considered: Encrypted from Start

**Why not use sops/sealed-secrets now?**
- Added complexity for single-user homelab
- No attack surface at this stage (local file on personal machine)
- Secrets file never leaves local disk (not synced, not in git)
- Deferring encryption is explicit technical debt we can repay when scaling

## Related ADRs

- (Future) ADR-002: Phase 2 server bootstrap validation
- (Future) ADR-003: K3s cluster initialization approach
