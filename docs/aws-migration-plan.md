# AWS Migration Plan

**Date:** 2026-06-06  
**Status:** Planning / Reference  
**Scope:** Full infrastructure transfer from bare-metal k3s homelab to AWS

---

## 1. Current Infrastructure Snapshot

Before mapping to AWS, here is what is currently running:

| Layer | Current Solution |
|---|---|
| Compute | Single bare-metal/VM Ubuntu node, k3s |
| GitOps | ArgoCD (app-of-apps) |
| Ingress | ingress-nginx + klipper-lb (k3s built-in) |
| TLS | cert-manager + Let's Encrypt DNS-01 via Cloudflare |
| Storage (block) | Longhorn (single-node, 1 replica) |
| Storage (large files) | NAS over NFS — Immich photos, Nextcloud data |
| Backups | Longhorn → NAS NFS target |
| Database | Self-managed PostgreSQL 14 (with pgvector), Redis 7 |
| Secrets | External Secrets Operator → 1Password / secret store |
| Auth/SSO | Authentik |
| Photo management | Immich (server + ML with OpenVINO GPU acceleration) |
| File sync | Nextcloud |
| Password manager | Vaultwarden |
| Monitoring | kube-prometheus-stack (Prometheus + Grafana + AlertManager) |
| DNS | Cloudflare (external), `*.in.alybadawy.com` wildcard |

---

## 2. AWS Services Mapping

Every homelab component has a direct or equivalent AWS counterpart.

### 2.1 Compute & Kubernetes

| Homelab | AWS Equivalent | Notes |
|---|---|---|
| k3s single node | **EKS** (Elastic Kubernetes Service) | Managed control plane, fully upstream k8s |
| k3s control plane | EKS control plane | $0.10/hr, AWS-managed |
| Ubuntu VM | EC2 worker node(s) | t3/m6i family; see Option comparison below |
| klipper-lb (ServiceLB) | **AWS Load Balancer Controller** | Provisions NLB/ALB automatically |

> **Alternative:** Run k3s on a single EC2 instance (like the homelab) — cheaper but you lose managed control plane, multi-AZ HA, and EKS integrations.

### 2.2 Storage

| Homelab | AWS Equivalent | Notes |
|---|---|---|
| Longhorn (block PVCs) | **EBS** (Elastic Block Store) via EBS CSI driver | gp3 volumes, per-PVC |
| NAS NFS (Immich data) | **EFS** (Elastic File System) | ReadWriteMany, NFS-compatible, no capacity planning |
| NAS NFS (Nextcloud data) | **EFS** | Same mount semantics as NFS |
| Longhorn backup target (NFS) | **S3** bucket | Longhorn natively supports S3 as backup target |
| Local-path storage (Grafana, Prometheus) | EBS or EFS | EBS preferred (ReadWriteOnce) |

> EFS is the cleanest NAS replacement — it is NFS-compatible and can be mounted into pods with the EFS CSI driver exactly like the current NFS mounts, with minimal manifest changes.

### 2.3 Networking

| Homelab | AWS Equivalent | Notes |
|---|---|---|
| Node IP + klipper-lb | **VPC** + public/private subnets | Proper network isolation |
| ingress-nginx (LoadBalancer) | ingress-nginx on **NLB**, or **ALB Ingress Controller** | ingress-nginx + NLB is the closest 1:1 drop-in |
| Local LAN DNS (`*.in.alybadawy.com`) | **Route 53** or keep Cloudflare | Route 53 integrates with cert-manager for DNS-01 |
| Cloudflare DNS-01 | Route 53 DNS-01 (or keep Cloudflare) | cert-manager supports both |

### 2.4 Database & Cache

| Homelab | AWS Equivalent | Notes |
|---|---|---|
| Self-managed PostgreSQL (on Longhorn) | **RDS PostgreSQL** or stay self-managed on EKS | RDS costs more but is fully managed |
| Self-managed Redis (in-cluster) | **ElastiCache** or stay self-managed on EKS | Same trade-off |

> For a personal homelab scale, keeping both self-managed on EKS (same as today) is the most cost-effective. Use RDS/ElastiCache if you want managed failover and backups.

### 2.5 Secrets & Configuration

| Homelab | AWS Equivalent | Notes |
|---|---|---|
| External Secrets Operator → 1Password | ESO → **AWS Secrets Manager** | ESO supports Secrets Manager natively |
| `cluster-config` ConfigMap/Secret | AWS Systems Manager **Parameter Store** | Or keep as k8s ConfigMap |

### 2.6 What Stays the Same

These tools are cloud-agnostic and require no replacement:

- **ArgoCD** — deploys identically on EKS
- **cert-manager** — works with Route 53 or Cloudflare DNS-01
- **Authentik** — stateless-friendly, runs as a k8s Deployment
- **Vaultwarden** — just needs block storage (EBS)
- **Immich** (server) — needs EFS for photo storage instead of NAS
- **Nextcloud** — needs EFS for file data instead of NAS
- **kube-prometheus-stack** — works on EKS unchanged
- **All application manifests** — mostly unchanged except storage class names and hostnames

---

## 3. Architecture Options

Three deployment options, from cheapest to most resilient.

### Option A: Single EC2 Node with k3s (Lift-and-Shift)

The same architecture as today, just on a cloud VM.

```
Internet
   │
   ▼
EC2 (t3.xlarge) ─── Elastic IP
   │  k3s
   │  ├── ingress-nginx
   │  ├── cert-manager
   │  ├── ArgoCD
   │  ├── Authentik
   │  ├── PostgreSQL (EBS PVC)
   │  ├── Redis
   │  ├── Immich (EFS mount)
   │  ├── Nextcloud (EFS mount)
   │  ├── Vaultwarden (EBS PVC)
   │  └── Prometheus/Grafana (EBS PVC)
   │
   ├── EBS (20GB+ block storage)
   ├── EFS (Immich + Nextcloud data)
   └── S3 (Longhorn/etcd backups)
```

**Pros:** Easiest migration, identical to homelab, lowest overhead  
**Cons:** No HA, single point of failure, manual k8s upgrades

---

### Option B: EKS with Single Node Group (Recommended)

Managed control plane, single worker node group, same application layout.

```
Internet
   │
   ▼
Route 53 / Cloudflare
   │
   ▼
NLB (Network Load Balancer)  ←── managed by AWS Load Balancer Controller
   │
   ▼
EKS Cluster
   │
   ├── Node Group (1x m6i.xlarge, 4 vCPU / 16GB)
   │   ├── ingress-nginx
   │   ├── cert-manager + ESO
   │   ├── ArgoCD
   │   ├── Authentik
   │   ├── PostgreSQL + Redis (EBS)
   │   ├── Immich server + ML (EFS)
   │   ├── Nextcloud (EFS)
   │   ├── Vaultwarden (EBS)
   │   └── Prometheus/Grafana (EBS)
   │
   ├── EBS volumes (20–50GB per stateful workload)
   ├── EFS filesystem (Immich + Nextcloud data, shared)
   ├── S3 bucket (Longhorn → Velero backups)
   └── AWS Secrets Manager (ESO backend)
```

**Pros:** Managed control plane, easier upgrades, AWS integrations  
**Cons:** $73/month EKS fee on top of compute

---

### Option C: EKS with Multi-AZ Node Group (Production HA)

Spread workers across 2–3 AZs, managed databases.

```
VPC
├── AZ-1 (us-east-1a)           ├── AZ-2 (us-east-1b)
│   ├── Private subnet           │   ├── Private subnet
│   │   └── EC2 worker           │   │   └── EC2 worker
│   └── Public subnet            │   └── Public subnet
│       └── NAT GW               │       └── NAT GW
│
├── EKS Control Plane (multi-AZ managed)
├── ALB (Application Load Balancer, multi-AZ)
├── RDS Aurora PostgreSQL (Multi-AZ)
├── ElastiCache Redis (Multi-AZ)
├── EFS (multi-AZ by default)
├── EBS (per-AZ, use EFS for cross-AZ PVCs)
└── S3 (backups, region-wide)
```

**Pros:** True HA, managed databases with automated failover  
**Cons:** Significantly higher cost (~3x), overkill for personal use

---

## 4. Cost Breakdown

All prices are AWS us-east-1 (N. Virginia), 2026 approximate on-demand rates. Use Reserved Instances (1-year) to cut compute 30–40%.

### Option A: Single EC2 + k3s

| Service | Spec | Monthly Cost |
|---|---|---|
| EC2 t3.xlarge | 4 vCPU / 16 GB, on-demand | ~$130 |
| EC2 t3.xlarge (1yr reserved) | Same | ~$85 |
| EBS gp3 | 100 GB (OS + PVCs) | ~$8 |
| EFS | 200 GB (Immich + Nextcloud) | ~$60 |
| Elastic IP | 1 IP | ~$0 (attached) |
| S3 | 100 GB backups | ~$3 |
| Data transfer out | ~50 GB/month | ~$5 |
| Route 53 hosted zone | 1 zone | ~$0.50 |
| **Total (on-demand)** | | **~$207/month** |
| **Total (1yr reserved)** | | **~$162/month** |

---

### Option B: EKS + Single Node Group (Recommended)

| Service | Spec | Monthly Cost |
|---|---|---|
| EKS control plane | Managed | ~$73 |
| EC2 m6i.xlarge worker | 4 vCPU / 16 GB, on-demand | ~$140 |
| EC2 m6i.xlarge (1yr reserved) | Same | ~$90 |
| EBS gp3 | 100 GB (PVCs) | ~$8 |
| EFS | 200 GB (Immich + Nextcloud) | ~$60 |
| NLB | 1 load balancer | ~$16 |
| S3 | 100 GB backups | ~$3 |
| AWS Secrets Manager | ~10 secrets | ~$4 |
| Data transfer out | ~50 GB/month | ~$5 |
| Route 53 hosted zone | 1 zone | ~$0.50 |
| **Total (on-demand)** | | **~$310/month** |
| **Total (1yr reserved)** | | **~$260/month** |

---

### Option C: EKS + Multi-AZ + Managed DB

| Service | Spec | Monthly Cost |
|---|---|---|
| EKS control plane | Managed | ~$73 |
| EC2 m6i.large × 2 workers | 2 vCPU / 8 GB each | ~$140 |
| RDS Aurora PostgreSQL | db.t4g.medium, Multi-AZ | ~$130 |
| ElastiCache Redis | cache.t4g.medium, Multi-AZ | ~$60 |
| NLB or ALB | 1 load balancer | ~$20 |
| NAT Gateways × 2 | 2 AZs | ~$65 |
| EFS | 200 GB | ~$60 |
| EBS gp3 | 50 GB | ~$4 |
| S3 | 100 GB | ~$3 |
| AWS Secrets Manager | ~10 secrets | ~$4 |
| Data transfer out | ~50 GB/month | ~$5 |
| Route 53 | 1 zone | ~$0.50 |
| **Total** | | **~$565/month** |

---

### GPU for Immich ML — The Big Wildcard

The current Immich ML deployment uses **OpenVINO GPU acceleration** via the host's integrated GPU (`/dev/dri`). On AWS:

| Option | Instance | Monthly Cost |
|---|---|---|
| No GPU (CPU-only ML) | Any instance | $0 extra — use `immich-machine-learning:release` image |
| GPU (g4dn.xlarge) | 1x NVIDIA T4, 4 vCPU / 16 GB | ~$380/month |
| GPU (g4ad.xlarge) | 1x AMD Radeon Pro, 4 vCPU / 16 GB | ~$240/month |

**Recommendation:** Switch to the CPU-only ML image on AWS. Immich ML on CPU is slower for initial indexing but perfectly adequate for ongoing use. The GPU instances cost more than the entire rest of the infrastructure.

---

## 5. What You Need to Change

### 5.1 Storage Classes

Replace Longhorn and local-path storage class references with EBS:

```yaml
# Before (homelab)
storageClassName: longhorn

# After (AWS)
storageClassName: gp3  # provisioned by EBS CSI driver
```

### 5.2 NAS Mounts → EFS

Immich and Nextcloud currently use `hostPath` volumes pointing at NFS mounts:

```yaml
# Before (homelab)
volumes:
  - name: data
    hostPath:
      path: /mnt/nas/immich
      type: Directory
```

```yaml
# After (AWS)
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: immich-efs-pvc   # backed by EFS CSI driver, ReadWriteMany
```

### 5.3 Immich ML Image

```yaml
# Before (homelab — uses OpenVINO + host GPU)
image: ghcr.io/immich-app/immich-machine-learning:release-openvino
env:
  - name: TRANSFORMERS_BACKEND
    value: openvino
  - name: OPENVINO_DEVICE
    value: GPU

# After (AWS — CPU inference)
image: ghcr.io/immich-app/immich-machine-learning:release
# remove TRANSFORMERS_BACKEND and OPENVINO_DEVICE env vars
# remove /dev/dri volume mounts
```

### 5.4 Longhorn Backup Target → S3

```yaml
# Before (longhorn/backup-target.yaml)
backupTarget: nfs://172.20.20.2:/var/nfs/shared/homelab/longhorn-backups

# After (with S3)
backupTarget: s3://your-bucket-name@us-east-1/longhorn-backups
# plus: set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in longhorn-system namespace
```

### 5.5 External Secrets Backend

Update the ClusterSecretStore from 1Password to AWS Secrets Manager:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

### 5.6 ingress-nginx LoadBalancer → NLB

Add the AWS NLB annotation to the ingress-nginx values:

```yaml
controller:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    externalTrafficPolicy: Local
```

### 5.7 cert-manager ClusterIssuer

If moving DNS to Route 53, update the DNS-01 solver:

```yaml
solvers:
  - dns01:
      route53:
        region: us-east-1
        hostedZoneID: Z1234567890ABC
```

If keeping Cloudflare, no change is needed.

---

## 6. Migration Phases

### Phase 1: Prepare AWS Account (1–2 days)

- Create AWS account (or use existing) with billing alerts
- Create VPC, subnets (public + private), security groups, NAT Gateway (optional for Option A)
- Create S3 bucket for backups
- Create EFS filesystem and mount targets in each subnet
- Set up IAM roles for EKS node group, EBS CSI, EFS CSI, Secrets Manager access
- Create AWS Secrets Manager entries for all secrets currently in 1Password / external store
- Set up Route 53 hosted zone (or confirm Cloudflare DNS remains)

### Phase 2: Provision Cluster (1 day)

**Option A (k3s on EC2):**
```bash
# Launch EC2 instance, then re-run provisioning scripts
./provision/rebuild.sh            # Steps 1–8 (adapted for EC2; restore-volumes needs S3 backend)
./provision/activate-gitops.sh
```

**Option B (EKS):**
- Create EKS cluster via `eksctl` or Terraform
- Install EBS CSI driver and EFS CSI driver
- Install AWS Load Balancer Controller
- Bootstrap ArgoCD (same script, pointed at the new kubeconfig)
- Apply root app-of-apps

### Phase 3: Data Migration (1–3 days, depending on data size)

This is the most time-consuming step. Migrate data before cutting over DNS.

1. **Immich photos (NAS → EFS):**
   ```bash
   # From the homelab NAS, sync to EFS via AWS DataSync or rsync through EC2
   aws datasync create-task ...  # recommended for large datasets
   # or
   rsync -avz /mnt/nas/immich/ <ec2-ip>:/mnt/efs/immich/
   ```

2. **Nextcloud files (NAS → EFS):**
   ```bash
   rsync -avz /mnt/nas/nextcloud/ <ec2-ip>:/mnt/efs/nextcloud/
   ```

3. **PostgreSQL databases:**
   ```bash
   # On homelab
   kubectl exec -n db deploy/postgres -- pg_dumpall -U postgres > all-databases.sql
   # Transfer and restore on AWS
   kubectl exec -n db deploy/postgres -- psql -U postgres < all-databases.sql
   ```

4. **Vaultwarden data (Longhorn PVC → EBS):**
   - Export Vaultwarden vault from the admin panel before migration
   - Import into the new instance after migration
   - Or: use Longhorn's S3 backup and restore to an EBS-backed PVC

5. **Authentik configuration:**
   - Export from Authentik admin panel: System → Backup
   - Import after new instance is running

### Phase 4: Application Verification (1–2 days)

Before DNS cutover:
- Access all services via port-forward and confirm functionality
- Verify all photos are present in Immich
- Verify Nextcloud files are accessible
- Verify Vaultwarden items are intact
- Verify Authentik SSO flows work
- Check Prometheus is scraping correctly
- Run a Longhorn backup and confirm it reaches S3

### Phase 5: DNS Cutover (minutes)

Update DNS records in Cloudflare or Route 53 to point to the new NLB/Elastic IP.
Lower TTLs to 60 seconds before cutover; restore to 300 after.

### Phase 6: Decommission Homelab (whenever ready)

- Keep homelab running in read-only mode for 1–2 weeks after cutover
- Confirm no data was missed
- Archive NAS data to cold storage (S3 Glacier or keep on NAS)
- Shut down homelab node

---

## 7. Key Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Immich ML performance degradation (no GPU) | Medium — slower face/object recognition | Switch to CPU image; run initial full re-index during off-hours |
| Data loss during NAS → EFS migration | High | Use AWS DataSync with checksums; verify before cutover |
| EFS cost surprise (charged per GB stored) | Medium | Monitor usage; consider S3 + mountpoint-s3 for cold photo archives |
| Longhorn → EBS PVC data migration | Medium | Use `kubectl cp` or Velero for live PVC migration |
| Authentik config loss | High | Export backup before decommissioning homelab |
| NAT Gateway cost (Option B/C) | Medium | Option A avoids NAT GW by using a public subnet; weigh against security |
| Spot interruption (if using Spot instances) | High | Use On-Demand or mix On-Demand + Spot with node draining |
| EKS upgrade complexity | Low | EKS manages control plane; node upgrades are manual but guided |

---

## 8. Cost Comparison Summary

| Setup | Monthly Cost | Best For |
|---|---|---|
| Current homelab (electricity only) | ~$10–20 | What you have now |
| Option A: k3s on EC2 | ~$162–207 | Simplest cloud migration |
| Option B: EKS single node | ~$260–310 | Recommended — managed k8s |
| Option C: EKS multi-AZ + managed DB | ~$565+ | True production HA |

> **Verdict:** Option B (EKS, single node, 1-year reserved) at ~$260/month is the sweet spot — you get a managed control plane, full AWS integrations, and minimal operational overhead, for roughly 10–15x the cost of the homelab electricity bill. If that cost is the goal, staying on homelab hardware is the better choice. If you want cloud benefits (no hardware to manage, elastic scaling, SLA-backed uptime), Option B is the right starting point.

---

## 9. Tools Needed for Migration

- `eksctl` or Terraform — cluster provisioning
- AWS CLI (`aws`) — S3, EFS, Secrets Manager operations
- `velero` — optional but recommended for PVC backup/restore between clusters
- `aws datasync` — large file migration from NAS to EFS
- `kubectl` — same as today
- `helm` + `kustomize` — same as today (ArgoCD handles this)

---

## 10. What Does NOT Change

The following parts of the current architecture remain identical and require no rework:

- ArgoCD app-of-apps structure (`k8s/apps/`, `k8s/components/`)
- cert-manager with Let's Encrypt (if keeping Cloudflare DNS-01)
- External Secrets Operator (change backend only)
- Vaultwarden, Authentik, Nextcloud, Immich application manifests (minor edits only)
- kube-prometheus-stack configuration
- GitOps workflow — push to main, ArgoCD syncs
- Provisioning scripts (Phase 2–6) can be reused for EC2 bootstrapping

The Git repository remains the single source of truth throughout. The migration is primarily an infrastructure swap (where the cluster runs), not an application rewrite.
