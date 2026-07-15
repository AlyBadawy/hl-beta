# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Provisioning workflow

For the full step-by-step provisioning process (Steps 1–8, activate-gitops, access URLs, and the configuration reference table), see the `provision` skill.

## Key Design Decisions

See Architecture Decision Records in `docs/ADR-*.md` for detailed rationale.

### Provisioning Design

1. **Configuration Collection** — Interactive bash scripts with validation
2. **Security** — Secrets file (mode 600), never in git
3. **Modularity** — Each script has single responsibility

### GitOps Bootstrap Design

4. **Staged bootstrap with a restore gate** — Steps 7–8 are deliberately separated from
   `activate-gitops.sh` so there is a safe window to restore Longhorn PVC backups before
   stateful apps start. Without this, GitOps would create new empty volumes on first sync.

5. **Imperative bootstrap, GitOps adoption** — ArgoCD and Longhorn are installed
   imperatively (Kustomize + Helm) then adopted by `k8s/apps/argocd.yaml` and
   `k8s/apps/longhorn.yaml` respectively. The `k8s/components/*/` directories serve as
   both the bootstrap source and the GitOps source — ensuring zero diff on adoption.

6. **Pre-bound PVCs** — On a rebuild, PVCs are created with `spec.volumeName` pointing
   to a specific restored Longhorn volume. When apps deploy, they bind to existing PVCs
   instead of triggering dynamic provisioning. Namespace must exist before PVC creation.

### Secrets Design

7. **HashiCorp Vault as the ESO secrets backend** — All application secrets are stored in
   Vault KV v2 under `secret/`. ESO reads from Vault via the `ClusterSecretStore/k8s-secrets`
   (Vault provider, Kubernetes auth). No secrets are stored in git or in a `secrets` namespace.
   Vault runs in the `security` namespace as a StatefulSet backed by a Longhorn PVC.

8. **Auto-unseal CronJob** — `vault-auto-unseal` runs every minute in the `security` namespace.
   It checks Vault's TCP port with `nc`, then runs `timeout 5 vault status` (plain `vault status`
   hangs at the HTTP layer while Longhorn reattaches storage — the timeout kills it and retries
   next minute). Exit code 2 = sealed → unseal; 0 = already unsealed; anything else = not ready,
   retry. The unseal key is stored in the `vault-unseal-key` Secret in the `security` namespace.

9. **ESO recovery CronJob** — `eso-recovery` runs every minute alongside the unseal CronJob.
   It checks if `vault-0` is ready (Vault's readiness probe fails when sealed, so `ready=true`
   means unsealed) and if the `k8s-secrets` ClusterSecretStore is degraded. When Vault comes
   back but ESO is still in exponential backoff, the job restarts the three ESO deployments in
   the `security` namespace to clear the backoff and force reconnection. During normal operation
   (store already Ready) it exits immediately — cheap to run every minute.

10. **Full post-reboot recovery is automatic** — After a reboot the sequence is:
    1. Vault pod starts sealed; ESO enters backoff (store degraded)
    2. `vault-auto-unseal` retries every minute; Longhorn reattaches the PVC (~4–5 min)
    3. Vault unseals; `vault-0` becomes Ready
    4. `eso-recovery` detects Vault ready + store degraded → restarts ESO
    5. ESO reconnects to Vault; all ExternalSecrets sync; apps recover
    Total time from boot to fully healthy: ~6 minutes. No manual intervention required.

11. **Rebuild requires only one manual secret** — After restoring Longhorn backups (which
    include Vault's data PVC), only `vault-unseal-key` needs to be seeded before GitOps runs.
    Everything else flows automatically: Vault unseals → ESO syncs → apps start.

## Documentation

- **`provision/README.md`** — How to use the provisioning scripts
- **`docs/01-provisioning-architecture.md`** — Architecture and design philosophy
- **`docs/ADR-*.md`** — Architecture Decision Records with rationale

## Developer Notes

### When Adding New Configurations

1. Add the variable with a sensible default to `provision/lib/defaults.sh`
2. Update the relevant sub-script to use the variable
3. Document the field in the Configuration Reference table above
4. Update `provision/README.md` if it changes how provisioning works
5. Create an ADR if it's a significant design decision

## Project Collaboration

**Important collaboration notes:**

- Discuss all architectural decisions before implementation
- Keep documentation updated with learnings and rationale
- Create ADRs when making significant design choices
- Explicitly ask questions when uncertain rather than assuming
- Document why decisions were made, not just how

---

**Last Updated:** 2026-06-07  
**Status:** All steps complete — GitOps active, fully automatic post-reboot recovery
