# ADR-001: Use HashiCorp Vault as the ESO Secrets Backend

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

1. **Manual seeding on every change.** Adding a new secret or rotating an existing one requires a human to run `bw get item ... | kubectl apply ...`. ESO's `refreshInterval` only refreshes the *destination* — it cannot detect that the source changed on its own.

2. **Manual seeding on every rebuild.** A new node requires seeding 9+ secrets into the `secrets` namespace before ArgoCD can sync any application. This is error-prone and a prerequisite gate before the cluster is usable.

### Why not keep Vaultwarden as the backend directly?

Vaultwarden implements the Bitwarden **password manager** API. ESO has no native Vaultwarden/Bitwarden password manager provider. The only bridge is the manual `bw` CLI step above. Bitwarden's **Secrets Manager** product does have an ESO provider, but it is a separate cloud-hosted product — Vaultwarden does not implement that API.

### Why not 1Password Connect?

1Password Connect is a self-hosted server that exposes a local HTTP API over a 1Password cloud vault. ESO has an official provider for it. It was evaluated and rejected because:

- The **primary storage** is 1Password's cloud (1password.com). Secrets live externally by design. For a self-hosted homelab, this is an undesirable external dependency for infrastructure credentials.
- **Cost:** 1Password Connect (Secrets Automation) may require a Teams plan (~$20/month) rather than the Personal plan (~$3/month). This requires verification and is a recurring cost.
- If 1password.com is unreachable, Connect can serve cached values but cannot accept new secrets or rotations until connectivity is restored.
- Introduces a cloud vendor dependency for a cluster whose goal is self-hosted operation.

### Why not Sealed Secrets?

Sealed Secrets encrypt secrets and commit them to git. Rejected because:

- Rotation requires re-sealing and committing to git — more friction than updating a value in a secrets store.
- The sealed key pair lives in the cluster — losing the cluster means losing the ability to decrypt without a separate key backup.
- No live sync; no single human-facing UI to manage values.

---

## Decision

Use **HashiCorp Vault (OSS)** as the ESO secrets backend, deployed as a StatefulSet in the cluster.

Vault's KV v2 secrets engine stores secrets as **key/value pairs** under organized paths, making it a natural fit for how application secrets are structured. ESO has an official, well-maintained Vault provider that reads directly from it.

The new flow:

```
Vault UI / CLI (in-cluster) → ESO (vault provider) → app namespace
```

### Resolving the unseal problem

Vault's primary objection for single-node homelabs is that it must be unsealed after every restart, otherwise ESO cannot sync secrets and apps cannot start. This is solved with two design choices:

1. **Initialize with a single unseal key** (`-key-shares=1 -key-threshold=1`). One key is sufficient for a single-node cluster where the goal is operational simplicity, not multi-party key custody.

2. **Auto-unseal via Kubernetes CronJob.** The unseal key is stored in a Kubernetes Secret (encrypted at rest by k3s). A CronJob runs every minute, checks Vault's seal status, and unseals automatically if needed. After a reboot, the worst-case delay before Vault is unsealed is ~60 seconds. During that window, ESO cannot refresh secrets, but existing Secret resources in application namespaces remain intact — pods do not restart.

```
@reboot (k3s restarts) → Vault pod starts (sealed) → CronJob fires within 60s
→ reads unseal key from k8s Secret → vault operator unseal → ESO resumes syncing
```

The unseal key in the k8s Secret is protected by k3s's at-rest encryption. This is meaningfully more secure than a plaintext file on disk and acceptable for a homelab threat model.

### Secrets structure

All secrets are stored in Vault's KV v2 engine under the `secret/` mount as flat key/value pairs. Each logical secret group is one Vault path with multiple keys:

```
secret/postgres-secret       → POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
secret/authentik-db          → username, password
secret/authentik-secret      → secret_key
secret/immich-db             → username, password
secret/nextcloud-db          → username, password
secret/pgadmin-secret        → PGADMIN_DEFAULT_EMAIL, PGADMIN_DEFAULT_PASSWORD
secret/resend-smtp           → host, port, username, password, from_address, use_tls
secret/grafana-admin         → admin-user, admin-password
secret/vaultwarden-admin     → ADMIN_TOKEN
```

### What changes

| Concern | Before | After |
|---|---|---|
| ESO backend | `kubernetes` provider → `secrets` namespace | `vault` provider → in-cluster Vault server |
| Secret format | k8s Secrets manually seeded | Vault KV v2 key/value pairs |
| Manual seeding (new secrets) | `bw CLI` + `kubectl apply` | `vault kv put secret/<path> key=value` |
| Manual seeding (rotation) | `bw CLI` + `kubectl apply` | `vault kv patch secret/<path> key=newvalue` |
| Rebuild bootstrap | 9 manual `kubectl` commands | Vault init (one-time) + unseal key secret |
| Auto-unseal | None — fully manual | Kubernetes CronJob reads from k8s Secret |
| `secrets` namespace | Required | Removed |
| ESO RBAC (SA, Role, RoleBinding) | Required | Replaced by Vault Kubernetes auth |
| Vaultwarden | Used for human-facing passwords | Unchanged — personal vault only |
| Cost | $0 | $0 |

### What does not change

- All `ExternalSecret` manifests — only `remoteRef.key` format changes (Vault path instead of k8s Secret name)
- The `ClusterSecretStore` name (`k8s-secrets`) — kept the same to minimize ExternalSecret changes
- ESO itself — only the provider block in the ClusterSecretStore changes
- All application manifests — they consume ESO-created Secrets identically

### Tradeoffs accepted

| Tradeoff | Mitigation |
|---|---|
| Vault must be initialized once manually after first install | One-time step; documented in migration plan |
| Up to 60s window after reboot where Vault is sealed | Existing app Secrets remain intact; pods do not restart; CronJob unseals automatically |
| Unseal key stored in a k8s Secret on the same cluster | k3s encrypts secrets at rest; acceptable for homelab threat model |
| Vault is another stateful service to manage | Longhorn backs its storage; single-node standalone mode is simple to operate |
| Seeding secrets requires `vault` CLI instead of `kubectl` | `vault kv put` is simpler than the current `bw` + `kubectl` two-step |

---

## Consequences

**Positive:**
- Secrets are stored entirely within the cluster — no cloud dependency, no external vendor.
- Key/value pair storage is explicit, auditable, and directly readable via `vault kv get`.
- Secret rotation is a single `vault kv patch` command; ESO picks it up on the next `refreshInterval`.
- Rebuild bootstrap is reduced to: initialize Vault + seed the unseal key k8s Secret.
- No subscription cost.
- Vault's policy engine enables fine-grained access control if needed in the future.
- Vault UI (`vault.in.alybadawy.com`) provides a human-readable view of all secrets and their versions.

**Negative:**
- Vault initialization is a one-time manual step that must be done before GitOps can sync apps.
- The unseal key must be preserved offline — losing it means Vault cannot be unsealed after a full data loss.
- Vault adds one more stateful service to the cluster (mitigated by Longhorn storage).

---

## Alternatives Considered

| Alternative | Reason rejected |
|---|---|
| Keep current `kubernetes` provider | Does not eliminate manual seeding — the core problem |
| 1Password Connect | Secrets stored in 1password.com cloud; potential Teams-plan cost; external cloud dependency |
| Bitwarden Secrets Manager | Cloud-hosted only; Vaultwarden does not implement the API |
| Sealed Secrets | Rotation requires git commits; no live sync |
| AWS Secrets Manager | Cloud-only; external dependency; cost |
