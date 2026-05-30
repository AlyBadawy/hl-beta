# ADR-002: GitOps Bootstrap Simplification

**Status:** Accepted  
**Date:** 2026-05-30  
**Context:** Phase 7 GitOps Bootstrap  
**Stakeholders:** Homelab Administrator

## Problem Statement

During Phase 7 (Bootstrap GitOps), we encountered a critical issue deploying ArgoCD via the Kubernetes Application CRD:

```
Error: UPGRADE FAILED: failed to create resource: Ingress in version "v1" cannot be handled as a Ingress: 
json: cannot unmarshal object into Go struct field IngressRule.spec.rules.host of type string
```

This error occurred when trying to deploy ArgoCD with complex, nested Helm values through the Application CRD's `helm.valuesObject` format.

### Root Cause Analysis

1. **JSON Serialization Issue:** The Application CRD uses `valuesObject` which is JSON-based. When Kubernetes tried to parse the generated Ingress resource, the nested `hosts` array was malformed.

2. **Complexity:** Attempting to pass the full ArgoCD configuration (including ingress with templated domain values) through Helm values during bootstrap created unnecessary coupling and fragility.

3. **Bootstrap Requirements:** We needed ArgoCD running immediately to bootstrap the cluster with the root-app Application, but the complex configuration prevented successful installation.

## Decision

Separate the bootstrap process into two distinct phases:

### Phase 1: Bootstrap (provision/scripts/bootstrap-gitops)
- Deploy ArgoCD with **minimal, simplified Helm values**
- No complex ingress configuration in Helm values
- Create Ingress as a **simple Kubernetes resource** via `kubectl apply`
- Keep bootstrap focused on getting the system running, not on full configuration

### Phase 2: GitOps Management (root-app Application)
- root-app takes over management of ArgoCD and nginx-ingress
- Configuration lives in git (git-ops/ folder)
- Full configuration refinement through git commits

## Implementation

### Bootstrap Script Changes
```bash
# Simplified bootstrap Helm values (no ingress)
ARGOCD_BOOTSTRAP_VALUES=$(cat <<'HELM_EOF'
server:
  replicas: 1
  insecure: true

controller:
  replicas: 1

repoServer:
  replicas: 1

persistence:
  enabled: false

redis:
  enabled: true

configs:
  cm:
    server.disable.auth: "false"
    server.insecure: "true"
HELM_EOF
)
```

### Ingress Creation (via kubectl, not Helm)
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
spec:
  ingressClassName: nginx
  rules:
    - host: "argo.{{ .Values.domain }}"  # Templated by bootstrap script
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

### Application CRD Values (Simplified)
The root-app's `argocd-app.yaml` also uses simplified values, letting Application defaults handle most configuration:

```yaml
helm:
  values: |
    server:
      replicas: 1
      insecure: true

    controller:
      replicas: 1

    repoServer:
      replicas: 1

    persistence:
      enabled: false

    redis:
      enabled: true

    configs:
      cm:
        server.disable.auth: "false"
        server.insecure: "true"
```

## Rationale

### Why Simplification Works
1. **Reduced Complexity:** Bootstrap has one job: get services running
2. **Avoidance of JSON Issues:** No complex nested structures in `valuesObject`
3. **Clean Separation:** Bootstrap is distinct from GitOps management
4. **Incremental Refinement:** root-app takes over once ArgoCD is operational
5. **Easier Troubleshooting:** Simpler configurations are easier to debug

### Why Separate Ingress Creation
1. **Avoids Helm Value Complexity:** Ingress creation is straightforward in kubectl
2. **Declarative:** Simple YAML is self-documenting
3. **Lower Risk:** Proven approach, no serialization issues
4. **Future Flexibility:** Ingress can later be moved to git-ops/ if needed

### Why helm.values > helm.valuesObject
1. **YAML String Format:** Less prone to JSON serialization edge cases
2. **More Readable:** YAML is easier to maintain than JSON structure definitions
3. **Template Friendly:** Helm template syntax (`{{ }}`) works naturally in YAML strings
4. **Industry Standard:** Most Helm/ArgoCD deployments use this pattern

## Trade-offs

### What We Gain
- ✓ Reliable bootstrap process
- ✓ Reduced complexity
- ✓ Clear separation of concerns
- ✓ Easier troubleshooting

### What We Give Up
- ✗ Single unified configuration source during bootstrap
- ✗ Cannot manage bootstrap Ingress via git (directly; root-app will manage later)

## Consequences

### Positive
1. Bootstrap process is now reliable and repeatable
2. clear role separation: bootstrap gets services running, GitOps manages configuration
3. Future administrators can understand the architecture easily
4. git-ops becomes the single source of truth for everything after bootstrap

### Negative (Mitigated)
1. Two ingress resources temporarily exist during bootstrap → Resolved when root-app syncs
2. Bootstrap ingress isn't git-managed → Will be managed by root-app eventually
3. Requires understanding of two-phase approach → Documented in this ADR

## Alternatives Considered

### Option A: Use helm.values in Application CRD (Chosen)
- **Pros:** YAML string format avoids JSON issues
- **Cons:** Still attempts full configuration during bootstrap
- **Result:** Works better but still complex for bootstrap

### Option B: Deploy ArgoCD Manually, Then Create Application (Chosen)
- **Pros:** Bootstrap is separate from GitOps
- **Cons:** Requires two different processes
- **Result:** Chosen for clean separation

### Option C: Use valuesFile Instead of valuesObject
- **Pros:** References git-ops/argocd/values.yaml directly
- **Cons:** Doesn't handle domain templating easily
- **Result:** Not viable without preprocessing

### Option D: Fully Inline All Values in Application
- **Pros:** Single source of truth
- **Cons:** Complex Application manifest, potential JSON issues
- **Result:** Rejected due to complexity

## Implementation Success

✓ Phase 7 Bootstrap completed successfully on 2026-05-30
- ArgoCD deployed and healthy
- Nginx-ingress deployed and operational
- root-app synced from git
- Ingress accessible at argo.in.alybadawy.com (after DNS configuration)

## Related Decisions

- [ADR-001](ADR-001-provisioning-script-design.md): Provisioning script architecture
- Future: ADR for root-app configuration management

## Review & Approval

- **Decision Maker:** Aly Badawy
- **Technical Review:** Claude (AI Assistant)
- **Approval Date:** 2026-05-30
- **Implementation Date:** 2026-05-30

## References

- Kubernetes Ingress API: https://kubernetes.io/docs/concepts/services-networking/ingress/
- ArgoCD Application CRD: https://argo-cd.readthedocs.io/en/stable/concepts/#argocd-application
- Helm Chart Specification: https://helm.sh/docs/topics/charts/

---

**Next Steps:** Document similar patterns for Phase 8 applications if needed. Consider whether future applications should follow the same two-phase bootstrap approach.
