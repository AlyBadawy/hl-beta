# K3s Homelab Cluster - Project Guide

**Project Goal:** Build a production-ready k3s cluster on Ubuntu 26.04 from scratch with best practices and fresh architecture decisions.

**Important:** This is a brand new project. Do not reference or assume anything from previous homelab decisions/conversations. Each decision should be made fresh based on current requirements.

## Provisioning workflow

For the full step-by-step provisioning process (Steps 1–7, activate-gitops, access URLs, and the configuration reference table), see the `provision` skill.

## Key Design Decisions

See Architecture Decision Records in `docs/ADR-*.md` for detailed rationale.

### Provisioning Design

1. **Configuration Collection** — Interactive bash scripts with validation
2. **Security** — Secrets file (mode 600), never in git
3. **Modularity** — Each script has single responsibility

### GitOps Bootstrap Design

4. **Manual checkpoint before GitOps takes over** — Step 7 is deliberately separated from
   `activate-gitops.sh` so there is a window to verify secrets and ArgoCD health before
   stateful apps start.

5. **Imperative bootstrap, GitOps adoption** — ArgoCD is installed imperatively
   (Kustomize + Helm) then adopted by `k8s/apps/argocd.yaml`. The `k8s/components/*/`
   directories serve as both the bootstrap source and the GitOps source — ensuring zero
   diff on adoption.

6. **Statically-bound NFS PVs** — All stateful app data lives on the NAS as native
   Kubernetes `PersistentVolume`s (`nfs:` source, `server`/`path` pointing at the NAS
   export). PVCs bind to a specific PV via `spec.volumeName` and `storageClassName: ""`,
   so no dynamic provisioning or restore step is needed on a rebuild — the data is
   already there, git just re-declares the same PV/PVC pair.

### Secrets Design

7. **HashiCorp Vault as the ESO secrets backend** — All application secrets are stored in
   Vault KV v2 under `secret/`. ESO reads from Vault via the `ClusterSecretStore/k8s-secrets`
   (Vault provider, Kubernetes auth). No secrets are stored in git or in a `secrets` namespace.
   Vault runs in the `security` namespace as a StatefulSet backed by an NFS-backed PVC
   (`file` storage backend — chosen because it doesn't rely on the mmap/byte-range
   locking that Vault's `raft` backend needs, which NFS handles poorly).

8. **Auto-unseal CronJob** — `vault-auto-unseal` runs every minute in the `security` namespace.
   It checks Vault's TCP port with `nc`, then runs `timeout 5 vault status` (the timeout
   guards against Vault being briefly unreachable right after a restart — kills the check
   and retries next minute). Exit code 2 = sealed → unseal; 0 = already unsealed; anything
   else = not ready, retry. The unseal key is stored in the `vault-unseal-key` Secret in
   the `security` namespace.

9. **ESO recovery CronJob** — `eso-recovery` runs every minute alongside the unseal CronJob.
   It checks if `vault-0` is ready (Vault's readiness probe fails when sealed, so `ready=true`
   means unsealed) and if the `k8s-secrets` ClusterSecretStore is degraded. When Vault comes
   back but ESO is still in exponential backoff, the job restarts the three ESO deployments in
   the `security` namespace to clear the backoff and force reconnection. During normal operation
   (store already Ready) it exits immediately — cheap to run every minute.

10. **Full post-reboot recovery is automatic** — After a reboot the sequence is:
    1. Vault pod starts sealed; ESO enters backoff (store degraded)
    2. `vault-auto-unseal` retries every minute until Vault's NFS-backed PVC mounts and
       the pod is reachable
    3. Vault unseals; `vault-0` becomes Ready
    4. `eso-recovery` detects Vault ready + store degraded → restarts ESO
    5. ESO reconnects to Vault; all ExternalSecrets sync; apps recover
    No manual intervention required. (Total time not yet re-measured since moving off
    Longhorn — the old ~6 minute figure was dominated by iSCSI PVC reattachment, which
    no longer applies with NFS.)

11. **Rebuild requires only one manual secret** — Since all stateful data lives on
    already-persistent NAS-backed NFS PVs, only `vault-unseal-key` needs to be seeded
    before GitOps runs. Everything else flows automatically: Vault unseals → ESO syncs →
    apps start.

### Networking Design

12. **k3s is pinned to the primary NIC** — `--node-ip=$SERVER_IP` is set on install and
    `node-ip: $SERVER_IP` is written to `/etc/rancher/k3s/config.yaml`, so cluster
    networking always binds to the primary (172.20.20.x) NIC regardless of what else is
    attached to the node — see `docs/ADR-0001-aredn-mesh-exposure.md`.

13. **AREDN mesh-facing apps use plain HTTP, no TLS** — `.local.mesh` hostnames on the
    AREDN network can't get a browser-trusted cert (no public CA can validate a private,
    non-internet-routable TLD), and a private CA's manual-trust overhead wasn't judged
    worth it since the mesh itself is the isolation boundary. ingress-nginx reaches the
    second NIC automatically via klipper-lb's `hostNetwork`; per-app Ingresses for mesh
    hosts just add `nginx.ingress.kubernetes.io/ssl-redirect: "false"` and no `tls:`
    block — see `docs/ADR-0001-aredn-mesh-exposure.md`.

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
