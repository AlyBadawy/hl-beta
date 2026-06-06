# ADR-001: Use 1Password Connect as the ESO Secrets Backend

**Date:** 2026-06-06  
**Status:** Accepted  
**Deciders:** Aly Badawy

---

## Context

The cluster uses External Secrets Operator (ESO) to distribute secrets into application namespaces. ESO requires a *secrets backend* — an authoritative store it can read from automatically.

### Current backend: Kubernetes `secrets` namespace

The ClusterSecretStore is configured with the ESO `kubernetes` provider, pointing at a dedicated `secrets` namespace in the same cluster. Every secret ESO needs must be manually created there:

```
Vaultwarden (web UI) → bw CLI (manual) → k8s Secret in `secrets` ns → ESO → app namespace
```

This works but has two significant problems:

1. **Manual seeding on every change.** Adding a new secret or rotating an existing one requires a human to run `bw get item ... | kubectl apply ...`. ESO's `refreshInterval` only refreshes the *destination* — it cannot detect that the source Secret changed on its own; that change still had to be made manually first.

2. **Manual seeding on every rebuild.** A new node requires seeding 9+ secrets into the `secrets` namespace before ArgoCD can sync any application. This is error-prone and must be done before the cluster is usable.

### Why not keep Vaultwarden as the backend directly?

Vaultwarden implements the Bitwarden **password manager** API. ESO has no native Vaultwarden/Bitwarden password manager provider. The only way to bridge them is the manual `bw` CLI step described above. Bitwarden's **Secrets Manager** product (a separate, cloud-hosted API) does have ESO support, but Vaultwarden does not implement that API and it cannot be self-hosted.

### Why not HashiCorp Vault?

HashiCorp Vault (OSS) is the industry-standard self-hosted secrets backend and ESO supports it natively. It was considered and rejected for this homelab because:

- Vault requires an **unseal** operation after every restart. On a single-node cluster, a node reboot leaves the cluster unable to distribute any secret until Vault is manually unsealed, creating a hard operational dependency.
- Vault is a complex, stateful service with its own HA, storage backend, policy engine, and audit log — substantial operational overhead for a personal cluster.
- The homelab already has Vaultwarden for human-facing credential storage. Running both Vault and Vaultwarden would mean managing two secret stores.

### Why not Sealed Secrets?

Sealed Secrets encrypt secrets and commit them to git, which solves the "secrets in git" problem differently. It was rejected because:

- Rotation requires re-sealing and committing to git, which is more friction than updating a value in a password manager.
- The sealed key pair is stored in the cluster — losing the cluster means losing the ability to decrypt without a key backup.
- It does not integrate with a human-facing password manager, so there is still no single source of truth.

---

## Decision

Use **1Password Connect** as the ESO secrets backend.

1Password Connect is a self-hosted server (two containers: `connect-api` + `connect-sync`) that exposes a local HTTP API over your 1Password vault. ESO has an official, well-maintained 1Password provider that reads from it directly.

The new flow:

```
1Password (app / web UI) → 1Password Connect (in-cluster) → ESO → app namespace
```

When a secret value is updated in the 1Password app or web UI, ESO picks it up automatically on the next `refreshInterval` cycle (default: 1 hour). No `bw` CLI, no manual `kubectl` commands.

### What changes

| Concern | Before | After |
|---|---|---|
| ESO backend | `kubernetes` provider → `secrets` namespace | `onepassword` provider → in-cluster Connect server |
| Manual seeding (new secrets) | `bw CLI` + `kubectl apply` | Update item in 1Password app only |
| Manual seeding (rotation) | `bw CLI` + `kubectl apply` | Update item in 1Password app only |
| Rebuild bootstrap secrets | 9 manual `kubectl` commands | 1 secret (`onepassword-credentials`) + 1 token |
| `secrets` namespace | Required | Removed |
| ESO RBAC (ServiceAccount, Role, RoleBinding) | Required | Removed |
| Vaultwarden | Stays — used for personal passwords | Unchanged |

### What does not change

- All `ExternalSecret` manifests (field references may need minor name alignment)
- The `ClusterSecretStore` name (`k8s-secrets`) — kept the same to avoid touching every ExternalSecret
- ESO itself — only the provider block in the ClusterSecretStore changes
- All application manifests — they consume ESO-created Secrets the same way

### Tradeoffs accepted

| Tradeoff | Mitigation |
|---|---|
| 1Password is a paid external service (~$3/month) | Cost is negligible; the operational benefit outweighs it |
| 1Password Connect pod must be healthy for ESO to sync | ESO caches the last-known secret values; apps do not restart if Connect is briefly unavailable |
| On a rebuild, 1Password Connect must start before ESO can sync any app | The `onepassword` ArgoCD app is assigned sync-wave `-1` so it deploys first |
| 1Password `1password-credentials.json` must be seeded once on a rebuild | This is a single, stable credential that never rotates unless explicitly revoked — far simpler than the current 9-secret bootstrap |

---

## Consequences

**Positive:**
- Secret rotation is now a one-step operation: update the value in 1Password.
- New cluster rebuilds require seeding exactly one credential file instead of nine secrets.
- ESO auto-refreshes all app secrets within one `refreshInterval` cycle of any change.
- The `secrets` namespace and associated RBAC are removed, simplifying the cluster.
- The rebuild guide (`docs/rebuild-guide.md`) becomes significantly shorter.

**Negative:**
- The cluster now depends on 1Password's cloud availability for the initial Connect authentication. Once Connect is running and authenticated, it caches credentials and operates independently of the 1Password cloud for the duration of the session.
- A 1Password subscription is required.

---

## Alternatives Considered

| Alternative | Reason rejected |
|---|---|
| Keep current `kubernetes` provider | Does not eliminate manual seeding — the core problem |
| HashiCorp Vault (OSS) | Unseal dependency on single-node cluster; high operational complexity |
| Bitwarden Secrets Manager (cloud) | Separate product from Vaultwarden; cloud-hosted only; additional cost |
| Sealed Secrets | Rotation still requires git commits; no live sync |
| AWS Secrets Manager | Cloud-only; incompatible with self-hosted homelab goals |
