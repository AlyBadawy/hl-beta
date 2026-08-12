# ADR-0001: Exposing apps to the AREDN mesh network via a second NIC

**Status:** Accepted
**Date:** 2026-08-12

## Context

The k3s node has a second, previously-unused NIC. It's being connected to an
AREDN mesh network (ham-radio-based, private, uses `.local.mesh` hostnames
instead of standard DNS — not internet-routable). Some apps need to be
reachable from that mesh network in addition to their existing
`*.in.alybadawy.com` exposure — starting with `emcomms` (nj2pc-oem), which
needs `al0y-emcomms.local.mesh`.

Two questions drove this decision: how to add the extra hostname, and
whether it can be TLS-secured.

## Decision

### No TLS for `.local.mesh` hosts

Every public CA, including Let's Encrypt (see `docs/tls-architecture.md`),
issues certificates via ACME, which requires proving control of a real,
publicly-delegatable domain — this cluster does that via Cloudflare DNS-01
for `*.in.alybadawy.com`. `.local.mesh` is not a real TLD and the AREDN
mesh isn't internet-connected, so no CA can validate it, and no browser will
ever trust a cert for it without manually installing a private root CA on
every device that accesses the mesh. Given the mesh network is itself the
isolation boundary, AREDN-facing hosts are served over **plain HTTP**, not a
self-signed/private-CA HTTPS setup — the added operational cost of
distributing and trusting a private CA wasn't judged worth it for this use
case.

### k3s is pinned to the primary NIC's IP

`provision/scripts/install-k3s` previously installed k3s with no
`--node-ip` flag, so k3s auto-detected which interface to bind cluster
traffic to (normally via the default route). With a second NIC present,
that auto-detection becomes a real risk — if routing ever preferred the
AREDN NIC, k3s/flannel/kubelet could bind cluster traffic to the wrong
interface. `--node-ip=$SERVER_IP` is now passed on install, and
`node-ip: $SERVER_IP` is written into `/etc/rancher/k3s/config.yaml` so it
also applies on restart, pinning cluster networking to the primary
(172.20.20.x) NIC regardless of what happens on the second one.

### No other cluster-side change is needed for reachability

ingress-nginx runs via k3s's built-in ServiceLB (klipper-lb), which uses
`hostNetwork` — it already listens on every IP bound to the node. Once the
second NIC has an IP on the AREDN subnet, ingress-nginx is reachable there
automatically; no Service/LoadBalancer or ingress-nginx config change is
required.

### Ingress pattern for AREDN hosts

`emcomms`'s Ingress lives in the external `nj2pc-oem` repo, not here
(`k8s/apps/emcomms.yaml` in this repo is only the ArgoCD `Application`
pointer). The pattern to follow there, and for any future AREDN-exposed
app:

- Add a `host:` rule for the `.local.mesh` hostname, same
  `ingressClassName: nginx` as every other app.
- **No `tls:` block**, and explicitly set
  `nginx.ingress.kubernetes.io/ssl-redirect: "false"`. Without this,
  ingress-nginx forces an HTTPS redirect by default (see
  `k8s/components/ingress-nginx/values.yaml`'s
  `default-ssl-certificate: networking/wildcard-tls`), which would present
  the `*.in.alybadawy.com` cert for a `.local.mesh` host — wrong domain,
  and pointless since the client only speaks HTTP anyway.
- Everything else about the existing per-app Ingress pattern (see
  `k8s/components/homepage/ingress.yaml` and similar) carries over
  unchanged.

## Out of scope (manual/OS-level)

- Bringing up the second NIC with a static IP on the AREDN subnet, and
  keeping the default route pinned to the primary NIC's gateway. This repo
  has no netplan/network-provisioning tooling (`SERVER_IP` is simply typed
  in interactively — see `provision/lib/defaults.sh:require_server_ip`), so
  this is done directly on the host.
- Making `al0y-emcomms.local.mesh` (and future mesh hostnames) resolve to
  the node's second-NIC IP on the mesh. That's AREDN node/router
  configuration (OLSR-based hostname/service announcement), not Kubernetes.

## Consequences

- AREDN-facing apps get no confidentiality/integrity guarantee from TLS —
  acceptable because the mesh itself is the trust boundary, and the
  alternative (private CA + manual trust distribution per device) wasn't
  worth the overhead for this network.
- The primary NIC's IP is now a hard-coded assumption in k3s's config
  rather than an auto-detected one. If the primary NIC's IP ever changes,
  both `K3S_INSTALL_EXEC` and `/etc/rancher/k3s/config.yaml` need updating
  (both already derive from the same `$SERVER_IP` prompt, so a rebuild
  handles this correctly as long as the same IP is entered).
