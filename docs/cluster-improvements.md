# Cluster Improvement Proposals

**Date:** 2026-06-05  
**Last updated:** 2026-06-05

| #   | Improvement                                    | Status                      |
| --- | ---------------------------------------------- | --------------------------- |
| 1   | inotify kernel tuning                          | ✅ Done                     |
| 2   | AlertManager notification receivers            | ⏳ Pending                  |
| 3   | ingress-nginx TLS hardening + security headers | ✅ Done                     |
| 4   | Certificate expiry PrometheusRule              | ✅ Done                     |
| 5   | Longhorn backup/health PrometheusRule          | ✅ Done                     |
| 6   | PostgreSQL logical backup CronJob              | ✅ Done                     |

---

## 1. inotify Kernel Tuning ✅ Done

**Symptom:** Many pods logged `fsnotify watcher: too many open files`.

**Applied on server** and codified in `provision/scripts/configure-cluster` (Step 4) for future rebuilds:

```
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
vm.max_map_count = 262144
```

Written to `/etc/sysctl.d/99-k8s-tuning.conf` and applied via `sysctl --system`.

---

## 2. AlertManager Notification Receivers ⏳ Pending

**Problem:** AlertManager is deployed but has zero receivers configured. Every Prometheus alert fires silently — no emails, no notifications.

**Proposed change:** Add an `alertmanagerSpec.config` block to `k8s/components/monitor/helm-values.yaml`. SMTP credentials should come from an ExternalSecret referencing the existing `k8s-secrets` ClusterSecretStore (reusing the SMTP creds already in `cluster-config` Secret).

```yaml
# In k8s/components/monitor/helm-values.yaml
alertmanager:
  alertmanagerSpec:
    # ... existing resources block ...
    config:
      global:
        smtp_smarthost: "smtp.resend.com:587"
        smtp_from: "noreply@alybadawy.com"
        smtp_require_tls: true
      route:
        receiver: "email"
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
        routes:
          - matchers:
              - severity = critical
            repeat_interval: 1h
      receivers:
        - name: "email"
          email_configs:
            - to: "alybadawy@icloud.com"
              send_resolved: true
```

SMTP username/password should be injected via an `alertmanagerConfigSecret` ExternalSecret rather than hardcoded in values.

**Verification:** Trigger a test alert via `amtool alert add alertname=Test severity=warning` and confirm email is received.

---

## 3. ingress-nginx TLS Hardening + Security Headers ✅ Done

**Applied in:**

- `k8s/components/ingress-nginx/values.yaml` — TLS hardening, security header reference, timeouts, `client-max-body-size: "100m"` global default
- `k8s/components/ingress-nginx/security-headers.yaml` — ConfigMap with `X-Frame-Options`, `X-XSS-Protection`, `X-Content-Type-Options`, `Referrer-Policy`, `Strict-Transport-Security`
- `k8s/components/ingress-nginx/kustomization.yaml` — added `security-headers.yaml` to resources

**Media app overrides** (already present, values adjusted to `5g`):

- `k8s/components/cloud/ingress.yaml` — `proxy-body-size: "5g"`, `proxy-read-timeout: "3600"`, `proxy-send-timeout: "3600"`
- `k8s/components/immich/ingress.yaml` — `proxy-body-size: "5g"`, `proxy-read-timeout: "3600"`, `proxy-send-timeout: "3600"`

**Verification:** `curl -I https://whoami.in.alybadawy.com` → confirm `Strict-Transport-Security` and `X-Frame-Options` headers are present.

---

## 4. Certificate Expiry PrometheusRule ✅ Done

**Applied in:**

- `k8s/components/cert-manager/prometheus-rule.yaml` — alerts for `CertificateExpiringSoon` (< 14 days) and `CertificateNotReady`
- `k8s/components/cert-manager/kustomization.yaml` — added to resources

**Verification:** Check Prometheus UI → Alerts tab → `CertificateExpiringSoon` and `CertificateNotReady` rules are listed.

---

## 5. Longhorn Backup Monitoring PrometheusRule ✅ Done

**Applied in:**

- `k8s/components/longhorn/prometheus-rule.yaml` — alerts for `LonghornVolumeUnhealthy`, `LonghornBackupFailed`, and `LonghornDiskPressure` (> 85%)
- `k8s/components/longhorn/kustomization.yaml` — added to resources

**Verification:** Check Prometheus UI → Alerts tab → Longhorn rules are listed.

---

## 6. PostgreSQL Logical Backup CronJob ✅ Done

**Problem:** Longhorn snapshots are crash-consistent at the filesystem level, not safe point-in-time backups for a running PostgreSQL instance.

**Applied in:**

- `k8s/components/db/pg-dump-cronjob.yaml` — daily `pg_dump` CronJob at 2 AM for `authentik`, `immich`, `nextcloud` databases; writes compressed `.dump` files to `/mnt/nas/backups/postgres`; prunes dumps older than 30 days
- `k8s/components/db/kustomization.yaml` — added to resources

**Verification:** After the first run, check `/mnt/nas/backups/postgres/` on the server for `.dump` files. Test restore with `pg_restore --list <file>`.
