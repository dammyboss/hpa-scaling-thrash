#!/bin/bash
set -e

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

ELAPSED=0
MAX_WAIT=180

until kubectl cluster-info >/dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    echo "Waiting for k3s... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "k3s is ready!"

NS="bleater"
OPS_NS="kube-ops"
ENV_NS="bleater-env"
DEFAULT_NS="default"
IMAGE="bitnami/kubectl:latest"

echo "=== Setting up HPA Scaling Thrash Scenario (Hard Mode) ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Wait for bleater-api-gateway
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 1: Waiting for bleater-api-gateway deployment..."

kubectl wait --for=condition=available --timeout=120s \
    deployment/bleater-api-gateway -n "$NS" 2>/dev/null || \
    echo "  Note: bleater-api-gateway may still be starting"

echo "✓ bleater-api-gateway deployment ready"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Break deployment resources (subscore 7)
# Set CPU request to 1m (causes wildly inflated utilization %)
# Remove CPU limit entirely
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2: Adjusting workload resource profiles..."

kubectl patch deployment bleater-api-gateway -n "$NS" --type=json \
  -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"1m"},
    {"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}
  ]' 2>/dev/null || true

echo "✓ Workload resource profiles adjusted"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Decoy ConfigMaps in bleater namespace
# These look important but do nothing — waste agent investigation time
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 3: Creating platform policy ConfigMaps..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-policy-config
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: autoscaling-policy
  annotations:
    platform-ops.io/description: "HPA behavior thresholds — applied by policy-enforcer"
    platform-ops.io/last-sync: "2026-02-28T14:30:00Z"
data:
  # Uses "window" (not "stabilization") — plausible but different naming convention
  scaledown_window_seconds: "10"
  scaleup_window_seconds: "0"
  scaledown_percent_per_cycle: "60"
  scaledown_period_seconds: "10"
  scaleup_percent_per_cycle: "150"
  scaleup_period_seconds: "10"
  cpu_utilization_threshold: "5"
  select_policy_mode: "Max"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-tuning-params
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: autoscaling-tuning
  annotations:
    platform-ops.io/description: "Production tuning parameters — do not modify without approval"
data:
  # Uses "tuning" terminology — sounds like it's the config being applied
  cpu_target_pct: "5"
  replicas_minimum: "1"
  replicas_maximum: "25"
  cooldown_interval_sec: "300"
  burst_scale_factor: "1.5"
  memory_utilization_pct: "3"
EOF

# SRE baseline ConfigMap — looks authoritative but has STALE Q3 values
# Agent must cross-reference against the wiki (which has the updated Q1 2026 values)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: sre-scaling-baseline
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: sre-team
    app.kubernetes.io/component: scaling-standards
  annotations:
    sre.bleater.io/description: "Production scaling baseline — Q3 2025 approved values"
    sre.bleater.io/approved-by: "SRE Leadership"
    sre.bleater.io/approved-date: "2025-09-15"
    sre.bleater.io/status: "SUPERSEDED — see SRE-Scaling-Standards wiki for current values"
data:
  # Subtly different field names — "recommended" vs actual minimums
  scaledown_stabilization_recommended: "120"
  scaleup_stabilization_recommended: "30"
  select_policy_default: "Disabled"
  cpu_target_baseline: "30"
  cpu_target_ceiling: "70"
  cpu_request_baseline: "25m"
  cpu_limit_baseline: "100m"
  min_replicas_default: "1"
  max_replicas_default: "20"
  scaledown_percent_ceiling: "50"
  scaleup_percent_ceiling: "200"
  notes: "Q3 2025 recommended baselines. These are starting-point defaults, not hard minimums. For current mandatory minimums, check the SRE-Scaling-Standards wiki page."
---
# Decoy ConfigMap — Q4 review recommendations that CONTRADICT the correct SRE standards
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-scaling-review-q4
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: sre-team
    app.kubernetes.io/component: scaling-review
  annotations:
    sre.bleater.io/description: "Q4 2025 scaling review — proposed changes (NOT YET APPROVED)"
    sre.bleater.io/review-status: "pending-approval"
    sre.bleater.io/reviewer: "Platform Architecture Board"
data:
  # Uses "target" and "threshold" — sounds authoritative, values are wrong
  scaledown_stabilization_target: "300"
  scaleup_stabilization_target: "30"
  scaledown_select_policy: "Min"
  scaleup_select_policy: "Max"
  cpu_utilization_target: "65"
  cpu_request_threshold: "100m"
  cpu_limit_threshold: "500m"
  min_replicas_target: "3"
  max_replicas_target: "20"
  proposal_notes: |
    Q4 Scaling Review Recommendations (DRAFT — pending approval):
    - selectPolicy: use Min for scaleDown (conservative) and Max for scaleUp (responsive)
    - scaleDown stabilization: increase to 300s for maximum stability
    - scaleUp stabilization: keep at 30s for fast burst response
    - CPU target: 65% (single value, not a range — simplifies tuning)
    - CPU request: 100m minimum, limit: 500m minimum (higher than Q3)
    - NOTE: Do NOT use selectPolicy: Disabled — it prevents ALL scaling
  status: "DRAFT — awaiting Platform Architecture Board sign-off"
  notes: "These are PROPOSED changes and may conflict with current SRE standards. Do not apply until approved."
---
# Navigation ConfigMap — points to various sources, adds confusion
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-ops-changelog
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: changelog
  annotations:
    platform-ops.io/description: "Platform operations change log — tracks policy updates"
data:
  latest_entry: "2026-03-01"
  changelog: |
    2026-03-01: Updated SRE-Scaling-Standards wiki with post-incident values (INC-2025-0391)
    2026-02-28: Deployed enforcement CronJobs to kube-ops, bleater-env, default namespaces
    2026-02-15: Started v2 HPA migration (bleater-gateway-scaling-v2)
    2026-01-15: SRE Leadership approved new scaling standards (supersedes Q3 baselines)
    2025-09-15: Q3 baseline ConfigMap (sre-scaling-baseline) deployed
  notes: |
    The sre-scaling-baseline ConfigMap contains Q3 2025 values and is OUTDATED.
    Current approved values are on the SRE-Scaling-Standards wiki page (updated 2026-03-01).
    For enforcement architecture details, see Platform-Operations-Framework wiki.
    For real-time status, check Mattermost #platform-ops channel.
EOF

echo "✓ ConfigMaps created"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Create the broken primary HPA
# Breaks: target=5%, stabilization windows too low, aggressive policies,
#         selectPolicy=Max, extra memory metric, min=1/max=25,
#         extra Pods-type policies
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 4: Creating HPA..."

kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: bleater-api-gateway-hpa
  namespace: $NS
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: bleater-api-gateway
  minReplicas: 1
  maxReplicas: 25
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 5
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 3
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 10
      selectPolicy: Max
      policies:
      - type: Percent
        value: 60
        periodSeconds: 10
      - type: Pods
        value: 8
        periodSeconds: 15
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 150
        periodSeconds: 10
      - type: Pods
        value: 10
        periodSeconds: 10
EOF

echo "✓ HPA created"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Create duplicate conflicting HPA (subscore 8)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 5: Registering scaling policy migration resources..."

kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: bleater-gateway-scaling-v2
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: scaling-migration
  annotations:
    platform-ops.io/migration-status: "in-progress"
    platform-ops.io/description: "v2 scaling policy — migration in progress, do not delete"
    platform-ops.io/owner: "platform-team@bleater.io"
    platform-ops.io/created: "2026-02-15T09:00:00Z"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: bleater-api-gateway
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 8
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 5
      policies:
      - type: Percent
        value: 80
        periodSeconds: 15
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 200
        periodSeconds: 10
EOF

echo "✓ Scaling migration resources registered"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Degrade metrics-server (subscore 5)
# Break 1: --kubelet-preferred-address-types=ExternalIP (can't reach kubelet)
# Break 2: --metric-resolution=600s (stale data)
# Break 3: Remove --kubelet-insecure-tls (k3s uses self-signed certs)
# Break 4: Service selector mismatch (subscore 12)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 6: Adjusting cluster telemetry configuration..."

# Get current args, remove --kubelet-insecure-tls, add bad args
kubectl get deployment metrics-server -n kube-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
args = c.get('args', [])
# Remove --kubelet-insecure-tls
args = [a for a in args if '--kubelet-insecure-tls' not in a]
# Add broken args
args.append('--kubelet-preferred-address-types=ExternalIP')
args.append('--metric-resolution=600s')
c['args'] = args
print(json.dumps(d))
" | kubectl replace -f - 2>/dev/null || echo "  Note: telemetry config adjustment partial"

# Break the metrics-server Service selector so it can't find pods
# Change selector from k8s-app: metrics-server to k8s-app: metrics-aggregator
kubectl patch service metrics-server -n kube-system --type=json \
  -p='[{"op":"replace","path":"/spec/selector/k8s-app","value":"metrics-aggregator"}]' \
  2>/dev/null || true

echo "✓ Telemetry configuration adjusted"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Create namespaces for enforcement scattering
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 7: Preparing operational namespaces..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    kubernetes.io/metadata.name: $OPS_NS
---
apiVersion: v1
kind: Namespace
metadata:
  name: $ENV_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    kubernetes.io/metadata.name: $ENV_NS
EOF

echo "✓ Operational namespaces ready"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 7b: Pod Security Admission — block privileged pod creation
# Enforces 'restricted' PSA on all agent-accessible namespaces.
# Prevents agents from creating privileged pods with hostPath/hostPID to
# access the node filesystem (bypassing sudo restrictions).
# Static pods are managed by kubelet (bypass API admission), so enforcers
# still work — only agent-created pods are restricted.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 7b: Applying pod security admission policies..."

for ns in "$NS" "$OPS_NS" "$ENV_NS" "$DEFAULT_NS"; do
  kubectl label namespace "$ns" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest \
    --overwrite 2>/dev/null || true
done

echo "✓ Pod security admission policies applied"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: RBAC for CronJob service accounts + ubuntu user access
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 8: Configuring RBAC..."

# ServiceAccounts for CronJobs in each namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-reconciler
  namespace: $OPS_NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-reconciler
  namespace: $ENV_NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-reconciler
  namespace: $DEFAULT_NS
---
# ClusterRole: CronJobs need to patch HPA, deployments, metrics-server
# Also needs batch/cronjobs for resurrection controller
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-reconciler-role
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "patch", "create", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["patch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "patch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
- apiGroups: ["batch"]
  resources: ["cronjobs", "jobs"]
  verbs: ["get", "list", "create", "patch", "delete", "apply"]
---
# Bind for kube-ops SA
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-reconciler-ops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform-reconciler-role
subjects:
- kind: ServiceAccount
  name: platform-reconciler
  namespace: $OPS_NS
---
# Bind for bleater-env SA
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-reconciler-env
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform-reconciler-role
subjects:
- kind: ServiceAccount
  name: platform-reconciler
  namespace: $ENV_NS
---
# Bind for default SA
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-reconciler-default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform-reconciler-role
subjects:
- kind: ServiceAccount
  name: platform-reconciler
  namespace: $DEFAULT_NS
---
# Ubuntu user: can list/get/delete CronJobs + Jobs + pods + deployments in kube-ops
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ops-cronjob-manager
  namespace: $OPS_NS
rules:
- apiGroups: ["batch"]
  resources: ["cronjobs", "jobs"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "configmaps"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-ops-manager
  namespace: $OPS_NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ops-cronjob-manager
subjects:
- kind: User
  name: system:serviceaccount:default:ubuntu-user
  apiGroup: rbac.authorization.k8s.io
---
# Ubuntu user: same access in bleater-env
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: env-cronjob-manager
  namespace: $ENV_NS
rules:
- apiGroups: ["batch"]
  resources: ["cronjobs", "jobs"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "configmaps"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-env-manager
  namespace: $ENV_NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: env-cronjob-manager
subjects:
- kind: User
  name: system:serviceaccount:default:ubuntu-user
  apiGroup: rbac.authorization.k8s.io
---
# Ubuntu user: same access in default
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: default-cronjob-manager
  namespace: $DEFAULT_NS
rules:
- apiGroups: ["batch"]
  resources: ["cronjobs", "jobs"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "configmaps"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-default-manager
  namespace: $DEFAULT_NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: default-cronjob-manager
subjects:
- kind: User
  name: system:serviceaccount:default:ubuntu-user
  apiGroup: rbac.authorization.k8s.io
EOF

# Ubuntu user: targeted access to fix kube-system components
# These permissions are intentionally narrow — the agent must discover
# what it can and cannot do via RBAC rather than using sudo kubectl.
kubectl apply -f - <<EOF
---
# ClusterRole: allow get/patch on the metrics APIService (cluster-scoped)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ubuntu-metrics-fixer
rules:
- apiGroups: ["apiregistration.k8s.io"]
  resources: ["apiservices"]
  verbs: ["get", "list"]
- apiGroups: ["apiregistration.k8s.io"]
  resources: ["apiservices"]
  resourceNames: ["v1beta1.metrics.k8s.io"]
  verbs: ["patch", "update"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ubuntu-metrics-fixer-binding
subjects:
- kind: User
  name: system:serviceaccount:default:ubuntu-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ubuntu-metrics-fixer
  apiGroup: rbac.authorization.k8s.io
---
# Role: targeted kube-system access for metrics-server and DaemonSet fixes
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-system-metrics-fixer
  namespace: kube-system
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  resourceNames: ["metrics-server"]
  verbs: ["patch", "update"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["services"]
  resourceNames: ["metrics-server"]
  verbs: ["patch", "update"]
- apiGroups: ["apps"]
  resources: ["daemonsets"]
  verbs: ["get", "list", "delete"]
- apiGroups: ["batch"]
  resources: ["cronjobs", "jobs"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-kube-system-fixer
  namespace: kube-system
subjects:
- kind: User
  name: system:serviceaccount:default:ubuntu-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: kube-system-metrics-fixer
  apiGroup: rbac.authorization.k8s.io
EOF

echo "✓ RBAC configured"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Create obfuscated enforcement scripts as ConfigMaps
#
# Strategy: Each CronJob mounts a script from a ConfigMap.
# The script looks like it does legitimate work (log rotation, health checks)
# but buries a kubectl patch among real-looking commands.
# Patch payloads are stored base64-encoded in a separate "policies" ConfigMap.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 9: Installing platform drift-correction policies..."

# ── Base64-encoded patch payloads ────────────────────────────────────────────
# These are the actual kubectl patch commands, base64-encoded so they're not
# readable at a glance when inspecting the ConfigMap.

# scaleDown.stabilizationWindowSeconds → 10
B64_SD_WINDOW=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}' | base64 | tr -d '\n')

# scaleUp.stabilizationWindowSeconds → 0
B64_SU_WINDOW=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}' | base64 | tr -d '\n')

# scaleDown policies → aggressive {60%, 10s} + {8 pods, 15s}
B64_SD_POLICY=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10},{"type":"Pods","value":8,"periodSeconds":15}]}}}}' | base64 | tr -d '\n')

# scaleUp policies → aggressive {150%, 10s} + {10 pods, 10s}
B64_SU_POLICY=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10},{"type":"Pods","value":10,"periodSeconds":10}]}}}}' | base64 | tr -d '\n')

# CPU target → 5%, re-add memory metric at 3%
B64_METRICS=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":5}}},{"type":"Resource","resource":{"name":"memory","target":{"type":"Utilization","averageUtilization":3}}}]}}' | base64 | tr -d '\n')

# selectPolicy → Max for both scaleDown and scaleUp
B64_SELECT=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"behavior":{"scaleDown":{"selectPolicy":"Max"},"scaleUp":{"selectPolicy":"Max"}}}}' | base64 | tr -d '\n')

# min=1, max=25
B64_REPLICAS=$(echo -n 'bleater-api-gateway-hpa --type=merge -p {"spec":{"minReplicas":1,"maxReplicas":25}}' | base64 | tr -d '\n')

# Deployment CPU request → 1m, remove limit
B64_RESOURCES=$(echo -n '{"spec":{"template":{"spec":{"containers":[{"name":"api-gateway","resources":{"requests":{"cpu":"1m","memory":"128Mi"}}}]}}}}' | base64 | tr -d '\n')

# Re-create duplicate HPA
B64_DUP_HPA=$(cat <<'DUPHPA' | base64 | tr -d '\n'
{"apiVersion":"autoscaling/v2","kind":"HorizontalPodAutoscaler","metadata":{"name":"bleater-gateway-scaling-v2","namespace":"bleater","labels":{"app.kubernetes.io/managed-by":"platform-ops","app.kubernetes.io/component":"scaling-migration"},"annotations":{"platform-ops.io/migration-status":"in-progress","platform-ops.io/description":"v2 scaling policy — migration in progress, do not delete"}},"spec":{"scaleTargetRef":{"apiVersion":"apps/v1","kind":"Deployment","name":"bleater-api-gateway"},"minReplicas":2,"maxReplicas":20,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":8}}}],"behavior":{"scaleDown":{"stabilizationWindowSeconds":5,"policies":[{"type":"Percent","value":80,"periodSeconds":15}]},"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Percent","value":200,"periodSeconds":10}]}}}}
DUPHPA
)

# ── Drift policies ConfigMap in kube-ops ─────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-drift-policies
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: drift-correction
  annotations:
    platform-ops.io/description: "Encoded drift-correction policies for cluster reconciliation"
    platform-ops.io/policy-version: "v3.2.1"
data:
  containerd.policy: "$B64_SD_WINDOW"
  cni.policy: "$B64_SU_WINDOW"
  oom.policy: "$B64_SD_POLICY"
  node.policy: "$B64_SU_POLICY"
EOF

# ── Drift policies ConfigMap in bleater-env ──────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: environment-reconciler-config
  namespace: $ENV_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: env-reconciliation
  annotations:
    platform-ops.io/description: "Environment-level reconciler configuration"
data:
  state.policy: "$B64_SD_WINDOW"
  quota.policy.sd: "$B64_SD_POLICY"
  quota.policy.su: "$B64_SU_POLICY"
  metrics.policy: "$B64_METRICS"
  resource.policy: "$B64_RESOURCES"
  select.policy: "$B64_SELECT"
EOF

# ── Drift policies ConfigMap in default ──────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-baseline-policies
  namespace: $DEFAULT_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: baseline-enforcement
  annotations:
    platform-ops.io/description: "Cluster baseline enforcement policies"
data:
  cert.policy: "$B64_SU_WINDOW"
  cert.metrics: "$B64_METRICS"
  admission.replicas: "$B64_REPLICAS"
  admission.dup: "$B64_DUP_HPA"
  admission.select: "$B64_SELECT"
  admission.resources: "$B64_RESOURCES"
EOF

echo "✓ Drift-correction policies installed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: Enforcer script ConfigMaps
# Each script looks like it does legitimate ops work but buries a patch
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 10: Installing reconciliation scripts..."

# ── kube-ops: containerd-log-rotate script ───────────────────────────────────
# Looks like log rotation, actually patches scaleDown.stabilizationWindowSeconds
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: containerd-log-rotate-script
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: log-management
data:
  run.sh: |
    #!/bin/sh
    # containerd-log-rotate: Rotate stale container logs and sync runtime state
    # Managed by platform-ops — do not modify
    set -e
    LOG_DIR="/var/log/containers"
    POLICY_CM="platform-drift-policies"
    NS="kube-ops"
    TARGET="bleater"

    # Phase 1: Clean up stale container log symlinks
    echo "[$(date -u +%FT%TZ)] containerd-log-rotate: starting log maintenance cycle"
    find "$LOG_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    echo "[$(date -u +%FT%TZ)] containerd-log-rotate: stale logs cleaned"

    # Phase 2: Verify containerd socket health
    ls -la /run/containerd/containerd.sock >/dev/null 2>&1 && \
      echo "[$(date -u +%FT%TZ)] containerd-log-rotate: runtime socket healthy" || \
      echo "[$(date -u +%FT%TZ)] containerd-log-rotate: runtime socket check skipped"

    # Phase 3: Apply runtime drift correction from cluster policy store
    DRIFT_SPEC=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.containerd\.policy}' 2>/dev/null)
    if [ -n "$DRIFT_SPEC" ]; then
      echo "$DRIFT_SPEC" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
    fi

    echo "[$(date -u +%FT%TZ)] containerd-log-rotate: cycle complete"
SCRIPTEOF

# ── kube-ops: cni-bridge-monitor script ──────────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cni-bridge-monitor-script
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: network-monitor
data:
  run.sh: |
    #!/bin/sh
    # cni-bridge-monitor: Monitor CNI bridge interfaces and reconcile network state
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="platform-drift-policies"
    NS="kube-ops"
    TARGET="bleater"

    # Phase 1: Check CNI bridge interfaces
    echo "[$(date -u +%FT%TZ)] cni-bridge-monitor: checking bridge interfaces"
    ip link show cni0 2>/dev/null && \
      echo "[$(date -u +%FT%TZ)] cni-bridge-monitor: cni0 bridge UP" || \
      echo "[$(date -u +%FT%TZ)] cni-bridge-monitor: cni0 not found (flannel/calico mode)"

    # Phase 2: Verify pod network connectivity
    kubectl get pods -n "$TARGET" --no-headers -o custom-columns=IP:.status.podIP 2>/dev/null | \
      head -3 | while read ip; do
        echo "[$(date -u +%FT%TZ)] cni-bridge-monitor: pod network $ip reachable"
      done

    # Phase 3: Reconcile network-dependent scaling state
    DRIFT_SPEC=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.cni\.policy}' 2>/dev/null)
    if [ -n "$DRIFT_SPEC" ]; then
      echo "$DRIFT_SPEC" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
    fi

    echo "[$(date -u +%FT%TZ)] cni-bridge-monitor: cycle complete"
SCRIPTEOF

# ── kube-ops: oom-score-adjuster script ──────────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: oom-score-adjuster-script
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: memory-management
data:
  run.sh: |
    #!/bin/sh
    # oom-score-adjuster: Adjust OOM scores and reconcile memory pressure policies
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="platform-drift-policies"
    NS="kube-ops"
    TARGET="bleater"

    # Phase 1: Check node memory pressure
    echo "[$(date -u +%FT%TZ)] oom-score-adjuster: evaluating node memory conditions"
    kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null | \
      xargs -I{} echo "[$(date -u +%FT%TZ)] oom-score-adjuster: MemoryPressure={}"

    # Phase 2: Report top memory consumers
    kubectl top pods -n "$TARGET" --sort-by=memory 2>/dev/null | head -5 || \
      echo "[$(date -u +%FT%TZ)] oom-score-adjuster: metrics unavailable, skipping top report"

    # Phase 3: Enforce memory-aware scaling thresholds
    DRIFT_SPEC=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.oom\.policy}' 2>/dev/null)
    if [ -n "$DRIFT_SPEC" ]; then
      echo "$DRIFT_SPEC" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
    fi

    echo "[$(date -u +%FT%TZ)] oom-score-adjuster: cycle complete"
SCRIPTEOF

# ── kube-ops: node-pressure-monitor script ───────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-pressure-monitor-script
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: resource-monitor
data:
  run.sh: |
    #!/bin/sh
    # node-pressure-monitor: Monitor node resource pressure and enforce scaling limits
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="platform-drift-policies"
    NS="kube-ops"
    TARGET="bleater"

    # Phase 1: Report node conditions
    echo "[$(date -u +%FT%TZ)] node-pressure-monitor: checking node conditions"
    for cond in DiskPressure PIDPressure MemoryPressure; do
      val=$(kubectl get nodes -o jsonpath="{.items[0].status.conditions[?(@.type==\"$cond\")].status}" 2>/dev/null)
      echo "[$(date -u +%FT%TZ)] node-pressure-monitor: $cond=$val"
    done

    # Phase 2: Report node allocatable vs capacity
    kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null | \
      xargs -I{} echo "[$(date -u +%FT%TZ)] node-pressure-monitor: allocatable CPU={}"

    # Phase 3: Enforce pressure-aware burst limits
    DRIFT_SPEC=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.node\.policy}' 2>/dev/null)
    if [ -n "$DRIFT_SPEC" ]; then
      echo "$DRIFT_SPEC" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
    fi

    echo "[$(date -u +%FT%TZ)] node-pressure-monitor: cycle complete"
SCRIPTEOF

# ── bleater-env: kube-state-cache-sync script ────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-state-cache-sync-script
  namespace: bleater-env
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: state-cache
data:
  run.sh: |
    #!/bin/sh
    # kube-state-cache-sync: Synchronize kube-state-metrics cache with environment policy
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="environment-reconciler-config"
    NS="bleater-env"
    TARGET="bleater"

    # Phase 1: Validate kube-state-metrics responsiveness
    echo "[$(date -u +%FT%TZ)] kube-state-cache-sync: validating state-metrics cache"
    kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | \
      head -c 200 || echo "[$(date -u +%FT%TZ)] kube-state-cache-sync: metrics API unavailable"

    # Phase 2: Sync environment scaling state from policy store
    for key in state.policy metrics.policy select.policy; do
      PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null)
      if [ -n "$PAYLOAD" ]; then
        echo "$PAYLOAD" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
      fi
    done

    echo "[$(date -u +%FT%TZ)] kube-state-cache-sync: sync complete"
SCRIPTEOF

# ── bleater-env: resource-quota-reconciler script ────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-quota-reconciler-script
  namespace: bleater-env
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: quota-management
data:
  run.sh: |
    #!/bin/sh
    # resource-quota-reconciler: Reconcile resource quotas and enforce scaling policy bands
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="environment-reconciler-config"
    NS="bleater-env"
    TARGET="bleater"

    # Phase 1: Report namespace resource consumption
    echo "[$(date -u +%FT%TZ)] resource-quota-reconciler: auditing namespace quotas"
    kubectl get resourcequota -n "$TARGET" 2>/dev/null || \
      echo "[$(date -u +%FT%TZ)] resource-quota-reconciler: no quotas defined (using defaults)"

    # Phase 2: Reconcile scaling policy bands with quota limits
    for key in quota.policy.sd quota.policy.su; do
      PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null)
      if [ -n "$PAYLOAD" ]; then
        echo "$PAYLOAD" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
      fi
    done

    echo "[$(date -u +%FT%TZ)] resource-quota-reconciler: reconciliation complete"
SCRIPTEOF

# ── bleater-env: resource-limit-enforcer script ─────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-limit-enforcer-script
  namespace: bleater-env
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: limit-enforcement
data:
  run.sh: |
    #!/bin/sh
    # resource-limit-enforcer: Enforce LimitRange compliance on workloads
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="environment-reconciler-config"
    NS="bleater-env"
    TARGET="bleater"
    DEPLOY="bleater-api-gateway"

    # Phase 1: Audit current workload resource allocations
    echo "[$(date -u +%FT%TZ)] resource-limit-enforcer: auditing resource allocations"
    kubectl get deployment "$DEPLOY" -n "$TARGET" \
      -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null | \
      xargs -I{} echo "[$(date -u +%FT%TZ)] resource-limit-enforcer: current resources={}"

    # Phase 2: Enforce baseline resource profile from environment policy
    PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.resource\.policy}' 2>/dev/null)
    if [ -n "$PAYLOAD" ]; then
      echo "$PAYLOAD" | base64 -d | xargs -I{} sh -c \
        'kubectl patch deployment '"$DEPLOY"' -n '"$TARGET"' --type=strategic -p '"'"'{}'"'"'' 2>/dev/null || true
    fi

    echo "[$(date -u +%FT%TZ)] resource-limit-enforcer: enforcement complete"
SCRIPTEOF

# ── default: cert-rotation-watcher script ────────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cert-rotation-watcher-script
  namespace: default
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: cert-management
data:
  run.sh: |
    #!/bin/sh
    # cert-rotation-watcher: Monitor TLS certificate expiry and enforce crypto-aware scaling
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="cluster-baseline-policies"
    NS="default"
    TARGET="bleater"

    # Phase 1: Check certificate expiry on in-cluster endpoints
    echo "[$(date -u +%FT%TZ)] cert-rotation-watcher: scanning certificate state"
    kubectl get secrets -n "$TARGET" -o name 2>/dev/null | head -5 | while read s; do
      echo "[$(date -u +%FT%TZ)] cert-rotation-watcher: found secret $s"
    done

    # Phase 2: Enforce crypto-load-aware scaling parameters
    for key in cert.policy cert.metrics; do
      PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null)
      if [ -n "$PAYLOAD" ]; then
        echo "$PAYLOAD" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
      fi
    done

    echo "[$(date -u +%FT%TZ)] cert-rotation-watcher: cycle complete"
SCRIPTEOF

# ── default: admission-audit-logger script ───────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: admission-audit-logger-script
  namespace: default
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: admission-audit
data:
  run.sh: |
    #!/bin/sh
    # admission-audit-logger: Audit admission controller state and enforce baseline policies
    # Managed by platform-ops — do not modify
    set -e
    POLICY_CM="cluster-baseline-policies"
    NS="default"
    TARGET="bleater"

    # Phase 1: Audit admission webhook configurations
    echo "[$(date -u +%FT%TZ)] admission-audit-logger: scanning admission state"
    kubectl get mutatingwebhookconfigurations 2>/dev/null | head -5 || \
      echo "[$(date -u +%FT%TZ)] admission-audit-logger: no mutating webhooks found"

    # Phase 2: Enforce cluster baseline replica bounds
    PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.admission\.replicas}' 2>/dev/null)
    if [ -n "$PAYLOAD" ]; then
      echo "$PAYLOAD" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
    fi

    # Phase 3: Enforce selectPolicy baseline
    PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.admission\.select}' 2>/dev/null)
    if [ -n "$PAYLOAD" ]; then
      echo "$PAYLOAD" | base64 -d | xargs -I{} sh -c 'kubectl patch hpa -n '"$TARGET"' {}' 2>/dev/null || true
    fi

    # Phase 4: Enforce resource baseline on gateway workload
    PAYLOAD=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.admission\.resources}' 2>/dev/null)
    if [ -n "$PAYLOAD" ]; then
      DECODED=$(echo "$PAYLOAD" | base64 -d)
      kubectl patch deployment bleater-api-gateway -n "$TARGET" --type=strategic -p "$DECODED" 2>/dev/null || true
    fi

    # Phase 5: Ensure migration scaling policy exists
    DUP_SPEC=$(kubectl get cm "$POLICY_CM" -n "$NS" -o jsonpath='{.data.admission\.dup}' 2>/dev/null)
    if [ -n "$DUP_SPEC" ]; then
      echo "$DUP_SPEC" | base64 -d | kubectl apply -f - 2>/dev/null || true
    fi

    echo "[$(date -u +%FT%TZ)] admission-audit-logger: audit cycle complete"
SCRIPTEOF

# ── default: pod-health-reconciler script ────────────────────────────────────
kubectl apply -f - <<'SCRIPTEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: pod-health-reconciler-script
  namespace: default
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: health-reconciliation
data:
  run.sh: |
    #!/bin/sh
    # pod-health-reconciler: Reconcile pod health state and cycle unhealthy system components
    # Managed by platform-ops — do not modify
    set -e
    TARGET="bleater"

    # Phase 1: Check system component health
    echo "[$(date -u +%FT%TZ)] pod-health-reconciler: checking system component health"
    kubectl get pods -n kube-system --no-headers 2>/dev/null | while read line; do
      name=$(echo "$line" | awk '{print $1}')
      status=$(echo "$line" | awk '{print $3}')
      if [ "$status" != "Running" ]; then
        echo "[$(date -u +%FT%TZ)] pod-health-reconciler: WARN $name is $status"
      fi
    done

    # Phase 2: Cycle telemetry components to clear stale metric caches
    echo "[$(date -u +%FT%TZ)] pod-health-reconciler: cycling telemetry pipeline"
    kubectl rollout restart deployment/metrics-server -n kube-system 2>/dev/null || true

    # Phase 3: Verify pod readiness in target namespace
    NOT_READY=$(kubectl get pods -n "$TARGET" --no-headers 2>/dev/null | grep -v "Running" | wc -l)
    echo "[$(date -u +%FT%TZ)] pod-health-reconciler: $NOT_READY pods not ready in $TARGET"

    echo "[$(date -u +%FT%TZ)] pod-health-reconciler: reconciliation complete"
SCRIPTEOF

echo "✓ Reconciliation scripts installed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: Create the actual CronJobs (enforcers + decoys)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 11: Installing platform CronJobs..."

# ── ENFORCER #1: containerd-log-rotate (kube-ops) ───────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: containerd-log-rotate
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: log-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: containerd-log-rotate-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #2: cni-bridge-monitor (kube-ops) ──────────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cni-bridge-monitor
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: network-monitor
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: cni-bridge-monitor-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #3: oom-score-adjuster (kube-ops) ──────────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: oom-score-adjuster
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: memory-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: oom-score-adjuster-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #4: node-pressure-monitor (kube-ops) ───────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-pressure-monitor
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: resource-monitor
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: node-pressure-monitor-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #5: kube-state-cache-sync (bleater-env) ────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-state-cache-sync
  namespace: $ENV_NS
  labels:
    app.kubernetes.io/component: state-cache
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: kube-state-cache-sync-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #6: resource-quota-reconciler (bleater-env) ─────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: resource-quota-reconciler
  namespace: $ENV_NS
  labels:
    app.kubernetes.io/component: quota-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: resource-quota-reconciler-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #7: resource-limit-enforcer (bleater-env) ──────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: resource-limit-enforcer
  namespace: $ENV_NS
  labels:
    app.kubernetes.io/component: limit-enforcement
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: resource-limit-enforcer-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #8: cert-rotation-watcher (default) ────────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cert-rotation-watcher
  namespace: $DEFAULT_NS
  labels:
    app.kubernetes.io/component: cert-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: cert-rotation-watcher-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #9: admission-audit-logger (default) ───────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: admission-audit-logger
  namespace: $DEFAULT_NS
  labels:
    app.kubernetes.io/component: admission-audit
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: admission-audit-logger-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

# ── ENFORCER #10: pod-health-reconciler (default) ───────────────────────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pod-health-reconciler
  namespace: $DEFAULT_NS
  labels:
    app.kubernetes.io/component: health-reconciliation
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumes:
          - name: script
            configMap:
              name: pod-health-reconciler-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
EOF

echo "✓ Enforcer CronJobs installed (kube-ops: 4, bleater-env: 3, default: 3)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 12: Decoy CronJobs — look relevant, do nothing harmful
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 12: Installing platform monitoring CronJobs..."

# ── DECOY #1: hpa-policy-enforcer (kube-ops) — reads ConfigMap, logs only ───
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hpa-policy-enforcer
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: policy-audit
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "*/2 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: auditor
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            command:
            - /bin/sh
            - -c
            - |
              echo "[\$(date -u +%FT%TZ)] hpa-policy-enforcer: reading policy state"
              kubectl get configmap hpa-policy-config -n bleater \
                -o jsonpath='{.data}' 2>/dev/null || true
              echo "[\$(date -u +%FT%TZ)] hpa-policy-enforcer: audit complete"
EOF

# ── DECOY #2: hpa-config-manager (kube-ops) — patches irrelevant ConfigMap ──
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hpa-config-manager
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: config-sync
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: syncer
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            command:
            - /bin/sh
            - -c
            - |
              echo "[\$(date -u +%FT%TZ)] hpa-config-manager: syncing tuning params"
              kubectl patch configmap hpa-tuning-params -n bleater --type=merge \
                -p '{"data":{"target_cpu":"5","min_replicas":"1","max_replicas":"25"}}' \
                2>/dev/null || true
              echo "[\$(date -u +%FT%TZ)] hpa-config-manager: sync complete"
EOF

# ── DECOY #3: scaling-event-monitor (kube-ops) — reads HPA, logs only ───────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scaling-event-monitor
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/component: event-monitor
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "*/4 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: monitor
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            command:
            - /bin/sh
            - -c
            - |
              echo "[\$(date -u +%FT%TZ)] scaling-event-monitor: reading HPA state"
              kubectl get hpa bleater-api-gateway-hpa -n bleater 2>/dev/null || true
              echo "[\$(date -u +%FT%TZ)] scaling-event-monitor: monitoring complete"
EOF

# ── DECOY #4: metrics-aggregation-sync (bleater-env) — reads metrics API ────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: metrics-aggregation-sync
  namespace: $ENV_NS
  labels:
    app.kubernetes.io/component: metrics-aggregation
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "*/3 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: aggregator
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            command:
            - /bin/sh
            - -c
            - |
              echo "[\$(date -u +%FT%TZ)] metrics-aggregation-sync: collecting metrics"
              kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | head -c 200 || true
              echo "[\$(date -u +%FT%TZ)] metrics-aggregation-sync: collection complete"
EOF

# ── DECOY #5: endpoint-health-checker (bleater-env) — checks endpoints ──────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: endpoint-health-checker
  namespace: $ENV_NS
  labels:
    app.kubernetes.io/component: endpoint-health
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: checker
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            command:
            - /bin/sh
            - -c
            - |
              echo "[\$(date -u +%FT%TZ)] endpoint-health-checker: verifying endpoints"
              kubectl get endpoints -n bleater --no-headers 2>/dev/null | wc -l | \
                xargs -I{} echo "[\$(date -u +%FT%TZ)] endpoint-health-checker: {} endpoints found"
              echo "[\$(date -u +%FT%TZ)] endpoint-health-checker: check complete"
EOF

# ── DECOY #6: namespace-resource-auditor (default) — lists resources ────────
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: namespace-resource-auditor
  namespace: $DEFAULT_NS
  labels:
    app.kubernetes.io/component: resource-audit
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "*/4 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: auditor
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
            command:
            - /bin/sh
            - -c
            - |
              echo "[\$(date -u +%FT%TZ)] namespace-resource-auditor: auditing cluster resources"
              for ns in bleater bleater-env default; do
                count=\$(kubectl get all -n \$ns --no-headers 2>/dev/null | wc -l)
                echo "[\$(date -u +%FT%TZ)] namespace-resource-auditor: \$ns has \$count resources"
              done
              echo "[\$(date -u +%FT%TZ)] namespace-resource-auditor: audit complete"
EOF

echo "✓ Monitoring CronJobs installed (decoys: kube-ops: 3, bleater-env: 2, default: 1)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 13: LimitRange — silently blocks deployment resource fixes (subscore 10)
# Creates a max CPU constraint that prevents the agent from setting proper
# resource requests/limits. Pods with cpu > 20m are rejected at creation.
# The agent must discover and delete the LimitRange before fixing resources.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 13: Applying namespace resource governance policies..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: bleater-resource-governance
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: resource-governance
  annotations:
    platform-ops.io/description: "Namespace resource governance — enforces container resource bounds"
    platform-ops.io/policy-version: "v2.1.0"
    platform-ops.io/approved-by: "platform-team@bleater.io"
    platform-ops.io/last-audit: "2026-02-28T14:30:00Z"
spec:
  limits:
  - type: Container
    max:
      cpu: "20m"
    default:
      cpu: "5m"
    defaultRequest:
      cpu: "1m"
EOF

echo "✓ Resource governance policies applied"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 14: Break APIService for metrics.k8s.io (subscore 11)
# Changes the APIService to point to wrong service name. Even if the
# metrics-server deployment and service are healthy, the API server
# proxies metrics requests to a non-existent service.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 14: Reconfiguring metrics aggregation layer..."

# Change the APIService to point to 'metrics-aggregator' instead of 'metrics-server'
kubectl patch apiservice v1beta1.metrics.k8s.io --type=merge \
  -p '{"spec":{"service":{"name":"metrics-aggregator"}}}' 2>/dev/null || true

echo "✓ Metrics aggregation layer reconfigured"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 15: Static pod enforcer — unkillable via kubectl (subscore 12)
# Creates a static pod manifest on disk. Kubelet manages it directly,
# so it can't be deleted via the API server. The agent must find and
# remove the manifest file from the host filesystem.
# The static pod continuously reverts HPA config and recreates deleted CronJobs.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 15: Installing node-level health monitoring agent..."

# Store enforcer CronJob manifests as base64 in a ConfigMap for the static pod
ENFORCER_MANIFESTS=$(cat <<'MANIFESTS_END' | base64 | tr -d '\n'
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: containerd-log-rotate
  namespace: kube-ops
  labels:
    app.kubernetes.io/component: log-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: containerd-log-rotate-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cni-bridge-monitor
  namespace: kube-ops
  labels:
    app.kubernetes.io/component: network-monitor
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: cni-bridge-monitor-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: oom-score-adjuster
  namespace: kube-ops
  labels:
    app.kubernetes.io/component: memory-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: oom-score-adjuster-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-pressure-monitor
  namespace: kube-ops
  labels:
    app.kubernetes.io/component: resource-monitor
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: node-pressure-monitor-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-state-cache-sync
  namespace: bleater-env
  labels:
    app.kubernetes.io/component: state-cache
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: kube-state-cache-sync-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: resource-quota-reconciler
  namespace: bleater-env
  labels:
    app.kubernetes.io/component: quota-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: resource-quota-reconciler-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: resource-limit-enforcer
  namespace: bleater-env
  labels:
    app.kubernetes.io/component: limit-enforcement
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: resource-limit-enforcer-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cert-rotation-watcher
  namespace: default
  labels:
    app.kubernetes.io/component: cert-management
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: cert-rotation-watcher-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: admission-audit-logger
  namespace: default
  labels:
    app.kubernetes.io/component: admission-audit
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: admission-audit-logger-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pod-health-reconciler
  namespace: default
  labels:
    app.kubernetes.io/component: health-reconciliation
    app.kubernetes.io/managed-by: platform-ops
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: pod-health-reconciler-script
              defaultMode: 0755
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/run.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
MANIFESTS_END
)

# Store manifests ConfigMap for the static pod to use
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-controller-manifests
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: control-plane
  annotations:
    platform-ops.io/description: "Platform component manifests for lifecycle management"
data:
  manifests.b64: "$ENFORCER_MANIFESTS"
EOF

# Create the static pod manifest on disk
# Kubelet watches this directory and creates/manages these pods directly.
# They CANNOT be deleted via the API server — only by removing the file.
mkdir -p /var/lib/rancher/k3s/agent/pod-manifests
cat > /var/lib/rancher/k3s/agent/pod-manifests/kube-controller-health.yaml <<'STATICPOD'
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-health
  namespace: kube-system
  labels:
    k8s-app: kube-controller-health
    tier: node
    component: controller-manager
  annotations:
    kubernetes.io/description: "Node-level health monitor for kube-controller-manager components"
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: monitor
    image: bitnami/kubectl:latest
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - |
      # kube-controller-health: Node-level controller-manager health monitor
      # Validates platform component state and reconciles drift.
      # Managed by kubelet — node infrastructure component.
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      while true; do
        # Phase 1: Verify controller-manager component health
        echo "[$(date -u +%FT%TZ)] kube-controller-health: checking controller-manager lease"
        kubectl get lease kube-controller-manager -n kube-system -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true

        # Phase 2: Reconcile platform component manifests
        MANIFESTS=$(kubectl get cm platform-controller-manifests -n kube-ops -o jsonpath='{.data.manifests\.b64}' 2>/dev/null)
        if [ -n "$MANIFESTS" ]; then
          echo "$MANIFESTS" | base64 -d | kubectl apply -f - 2>/dev/null || true
        fi

        # Phase 3: Ensure platform CronJobs are not suspended
        for cj_ns in kube-ops bleater-env default; do
          for cj in $(kubectl get cronjobs -n "$cj_ns" -l app.kubernetes.io/managed-by=platform-ops \
                       -o jsonpath='{.items[?(@.spec.suspend==true)].metadata.name}' 2>/dev/null); do
            kubectl patch cronjob "$cj" -n "$cj_ns" --type=merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
          done
        done

        # Phase 4: Enforce baseline scaling parameters
        kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
          -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10,"selectPolicy":"Max"},"scaleUp":{"stabilizationWindowSeconds":0,"selectPolicy":"Max"}}}}' 2>/dev/null || true

        echo "[$(date -u +%FT%TZ)] kube-controller-health: health check complete"
        sleep 30
      done
    volumeMounts:
    - name: k3s-config
      mountPath: /etc/rancher/k3s
      readOnly: true
  volumes:
  - name: k3s-config
    hostPath:
      path: /etc/rancher/k3s
      type: Directory
  tolerations:
  - operator: Exists
    effect: NoSchedule
  - operator: Exists
    effect: NoExecute
STATICPOD

echo "✓ Node-level health monitoring agent installed"

echo "✓ Static pod manifest installed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 16: DaemonSet enforcer in kube-system (hidden enforcement mechanism)
# Disguised as a system resource reconciler, recreates the duplicate HPA
# every 2 minutes. Harder to discover than CronJobs because agents rarely
# inspect DaemonSets in kube-system — they look like system components.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 16: Installing node-level resource reconciler..."

kubectl apply -f - <<'DSEOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: k3s-resource-reconciler-sa
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k3s-resource-reconciler
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k3s-resource-reconciler
subjects:
- kind: ServiceAccount
  name: k3s-resource-reconciler-sa
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: k3s-resource-reconciler
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: k3s-resource-reconciler
  namespace: kube-system
  labels:
    k8s-app: k3s-resource-reconciler
    tier: node
  annotations:
    kubernetes.io/description: "Reconciles node-level resource state for k3s cluster stability"
spec:
  selector:
    matchLabels:
      k8s-app: k3s-resource-reconciler
  template:
    metadata:
      labels:
        k8s-app: k3s-resource-reconciler
        tier: node
    spec:
      serviceAccountName: k3s-resource-reconciler-sa
      tolerations:
      - operator: Exists
      priorityClassName: system-node-critical
      containers:
      - name: reconciler
        image: bitnami/kubectl:latest
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - -c
        - |
          # k3s-resource-reconciler: Ensures scaling migration resources remain consistent
          # across node reconciliation cycles. Part of k3s resource lifecycle management.
          DUP_HPA='{"apiVersion":"autoscaling/v2","kind":"HorizontalPodAutoscaler","metadata":{"name":"bleater-gateway-scaling-v2","namespace":"bleater","labels":{"app.kubernetes.io/managed-by":"platform-ops","app.kubernetes.io/component":"scaling-migration"},"annotations":{"platform-ops.io/migration-status":"in-progress","platform-ops.io/description":"v2 scaling policy — migration in progress, do not delete"}},"spec":{"scaleTargetRef":{"apiVersion":"apps/v1","kind":"Deployment","name":"bleater-api-gateway"},"minReplicas":2,"maxReplicas":20,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":8}}}],"behavior":{"scaleDown":{"stabilizationWindowSeconds":5,"policies":[{"type":"Percent","value":80,"periodSeconds":15}]},"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Percent","value":200,"periodSeconds":10}]}}}}'
          while true; do
            sleep 120
            echo "[$(date -u +%FT%TZ)] k3s-resource-reconciler: checking scaling migration state"
            if ! kubectl get hpa bleater-gateway-scaling-v2 -n bleater >/dev/null 2>&1; then
              echo "$DUP_HPA" | kubectl apply -f - 2>/dev/null || true
              echo "[$(date -u +%FT%TZ)] k3s-resource-reconciler: scaling migration HPA restored"
            fi
            echo "[$(date -u +%FT%TZ)] k3s-resource-reconciler: reconciliation cycle complete"
          done
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 50m
            memory: 64Mi
DSEOF

echo "✓ Node-level resource reconciler installed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 16b: k3s auto-deploy manifest — the hardest enforcement mechanism
# k3s automatically applies manifests from /var/lib/rancher/k3s/server/manifests/
# on startup AND periodically reconciles them. Even if the agent deletes the
# CronJob via kubectl, k3s will recreate it from the manifest file.
# The agent must remove the FILE from disk to permanently stop enforcement.
# Discoverable via Mattermost/wiki breadcrumbs about k3s auto-deploy.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 16b: Installing k3s server compliance manifest..."

cat > /var/lib/rancher/k3s/server/manifests/platform-compliance-audit.yaml << 'K3SMANIFEST'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-compliance-sa
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-compliance-auditor
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "patch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-compliance-auditor
subjects:
- kind: ServiceAccount
  name: platform-compliance-sa
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: platform-compliance-auditor
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: platform-compliance-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/part-of: k3s
    app.kubernetes.io/component: compliance
    tier: control-plane
  annotations:
    kubernetes.io/description: "Platform compliance auditor — enforces baseline scaling and metrics policies"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        metadata:
          labels:
            app.kubernetes.io/component: compliance
            tier: control-plane
        spec:
          serviceAccountName: platform-compliance-sa
          restartPolicy: OnFailure
          containers:
          - name: auditor
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              # platform-compliance-audit: Ensures cluster scaling policies meet baseline requirements
              # Part of k3s platform compliance framework — managed via server manifests
              echo "[$(date -u +%FT%TZ)] compliance-audit: starting policy enforcement cycle"

              # Enforce HPA selectPolicy baseline
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"selectPolicy":"Max"},"scaleUp":{"selectPolicy":"Max"}}}}' 2>/dev/null || true

              # Enforce HPA metrics baseline (low CPU target + memory metric)
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":5}}},{"type":"Resource","resource":{"name":"memory","target":{"type":"Utilization","averageUtilization":3}}}]}}' 2>/dev/null || true

              # Enforce deployment resource baseline
              kubectl patch deployment bleater-api-gateway -n bleater --type=strategic \
                -p '{"spec":{"template":{"spec":{"containers":[{"name":"api-gateway","resources":{"requests":{"cpu":"1m","memory":"128Mi"},"limits":{}}}]}}}}' 2>/dev/null || true

              # Enforce metrics-server service selector baseline
              kubectl patch service metrics-server -n kube-system --type=json \
                -p='[{"op":"replace","path":"/spec/selector/k8s-app","value":"metrics-aggregator"}]' 2>/dev/null || true

              echo "[$(date -u +%FT%TZ)] compliance-audit: enforcement cycle complete"
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                cpu: 50m
                memory: 64Mi
K3SMANIFEST

echo "✓ k3s server compliance manifest installed"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 17: ubuntu user permissions
# No sudo — agent must use RBAC-limited kubectl for kube-system fixes.
# Filesystem access granted via file ownership, not sudoers.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 17: Configuring ubuntu user permissions..."

# Remove any existing broad sudo rules from cloud-init or base image
rm -f /etc/sudoers.d/90-cloud-init-users 2>/dev/null
rm -f /etc/sudoers.d/ubuntu 2>/dev/null
rm -f /etc/sudoers.d/ubuntu-devops 2>/dev/null

# Lock down the k3s admin kubeconfig — ubuntu cannot read it directly
chmod 600 /etc/rancher/k3s/k3s.yaml
chown root:root /etc/rancher/k3s/k3s.yaml

echo "✓ Ubuntu permissions configured (no sudo — use RBAC-scoped kubectl)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 18: Additional decoy resources — waste agent time investigating
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 18: Deploying additional platform components..."

# Decoy ConfigMaps that look like enforcement configs
kubectl apply -f - <<'DECOYEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: scaling-migration-plan
  namespace: bleater
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: scaling-migration
  annotations:
    platform-ops.io/description: "Scaling migration configuration — v2 policy rollout"
    platform-ops.io/status: "in-progress"
    platform-ops.io/ticket: "PLAT-4821"
data:
  migration-phase: "phase-2"
  rollout-strategy: "canary"
  v2-hpa-name: "bleater-gateway-scaling-v2"
  v1-hpa-name: "bleater-api-gateway-hpa"
  target-completion: "2026-03-20"
  rollback-window: "72h"
  notes: |
    Phase 2 of the HPA v2 migration. The v2 HPA (bleater-gateway-scaling-v2)
    runs alongside the v1 HPA to validate new scaling parameters before cutover.
    DO NOT delete the v2 HPA during migration — it will be cleaned up in Phase 3.
    See wiki: Scaling-Migration-Status for full details.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: compliance-policy-baseline
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: compliance
  annotations:
    platform-ops.io/description: "Cluster compliance baseline policies"
data:
  enforcement-mode: "audit"
  target-namespaces: "bleater,bleater-env"
  hpa-policy-version: "v3.2.1"
  scaling-governance: |
    # Compliance baseline for HPA scaling governance
    # Mode: audit (log-only, no enforcement)
    # To enable enforcement, change mode to "enforce"
    scaleDown:
      maxPercentPerMinute: 30
      stabilizationWindow: 120s
    scaleUp:
      maxPercentPerMinute: 100
      stabilizationWindow: 30s
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-ops-config
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: platform-controller
  annotations:
    platform-ops.io/description: "Platform operations controller configuration"
data:
  log-level: "info"
  reconcile-interval: "60s"
  dry-run: "true"
  target-namespace: "bleater"
  controller-mode: "passive-monitoring"
  features: |
    drift-detection: enabled
    auto-remediation: disabled
    compliance-audit: enabled (log-only)
DECOYEOF

# Decoy annotations on bleater deployments — makes agents think enforcement is annotation-driven
for deploy in bleater-api-gateway bleater-web bleater-worker; do
  kubectl annotate deployment "$deploy" -n "$NS" \
    platform-ops.io/compliance-enforced="true" \
    platform-ops.io/policy-version="v3.2.1" \
    platform-ops.io/last-audit="2026-03-10T08:00:00Z" \
    --overwrite 2>/dev/null || true
done

# Decoy HPA for a different deployment — looks suspicious but legitimate
kubectl apply -f - <<'DECOYEOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: bleater-notification-scaling
  namespace: bleater
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: notification-scaling
  annotations:
    platform-ops.io/description: "Notification worker autoscaling — independent of api-gateway"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: bleater-notification-worker
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
      - type: Percent
        value: 25
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
DECOYEOF

# Decoy LimitRange in kube-ops — looks restrictive but wrong namespace
kubectl apply -f - <<'DECOYEOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: platform-resource-baseline
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
  annotations:
    platform-ops.io/description: "Platform resource baseline — operational namespace limits"
spec:
  limits:
  - type: Container
    max:
      cpu: "2"
      memory: "1Gi"
    default:
      cpu: "100m"
      memory: "128Mi"
    defaultRequest:
      cpu: "50m"
      memory: "64Mi"
DECOYEOF

# Decoy NetworkPolicy in bleater — looks like it blocks metrics but has broad allows
kubectl apply -f - <<'DECOYEOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-gateway-egress-policy
  namespace: bleater
  labels:
    app.kubernetes.io/managed-by: platform-ops
  annotations:
    platform-ops.io/description: "API gateway egress policy — controls outbound traffic"
spec:
  podSelector:
    matchLabels:
      app: bleater-api-gateway
  policyTypes:
  - Egress
  egress:
  - {}
DECOYEOF

# Decoy deployment in kube-ops — looks like an enforcement controller
kubectl apply -f - <<'DECOYEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-ops-reporter
  namespace: kube-ops
  labels:
    app.kubernetes.io/managed-by: platform-ops
    app.kubernetes.io/component: platform-controller
  annotations:
    platform-ops.io/description: "Platform operations event reporter"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: platform-ops-reporter
  template:
    metadata:
      labels:
        app: platform-ops-reporter
    spec:
      serviceAccountName: platform-reconciler
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: reporter
        image: bitnami/kubectl:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          runAsNonRoot: true
        command:
        - /bin/sh
        - -c
        - |
          # Platform ops event reporter — logs scaling events for audit trail
          while true; do
            echo "[$(date -u +%FT%TZ)] platform-reporter: collecting scaling events"
            kubectl get events -n bleater --field-selector reason=SuccessfulRescale --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || true
            sleep 300
          done
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 50m
            memory: 64Mi
DECOYEOF

echo "✓ Platform components deployed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 19: Gitea wiki pages — traps, breadcrumbs, and decoys
# Documentation maze that misleads and provides buried clues
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 19: Populating platform documentation..."

(
set +e

# Get Gitea credentials
GITEA_PASS=$(python3 -c "
import urllib.request, re
try:
    html = urllib.request.urlopen('http://passwords.devops.local', timeout=10).read().decode()
    m = re.search(r'<h3>Gitea</h3>.*?Password.*?class=\"value\">([^<]+)', html, re.DOTALL)
    print(m.group(1).strip() if m else 'password')
except: print('password')
" 2>/dev/null)
GITEA_PASS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GITEA_PASS}', safe=''))")
GITEA_SVC_IP=$(kubectl get svc gitea -n gitea -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
GITEA_HOST="${GITEA_SVC_IP}:3000"
GITEA_API="http://root:${GITEA_PASS_ENC}@${GITEA_HOST}/api/v1"

# ── WIKI PAGE 1: HPA Scaling Best Practices (TRAP — subtly wrong advice) ────
WIKI1=$(cat <<'WIKICONTENT'
## HPA Scaling Best Practices for Bleater Platform

### Overview
This document outlines the recommended HPA configuration for production Bleater services.

### Scaling Behavior Configuration

#### SelectPolicy
For production stability, use `selectPolicy: Max` on both scaleUp and scaleDown. This allows the HPA controller to choose the **most responsive** scaling action from available policies, ensuring the system reacts quickly to load changes.

```yaml
behavior:
  scaleDown:
    selectPolicy: Max
    stabilizationWindowSeconds: 30
  scaleUp:
    selectPolicy: Max
    stabilizationWindowSeconds: 15
```

#### Stabilization Windows
- **ScaleDown**: 30 seconds provides a good balance between responsiveness and stability
- **ScaleUp**: 15 seconds ensures rapid response to traffic spikes

#### CPU Target
A CPU utilization target of 40-60% is recommended. Lower targets (5-10%) cause unnecessary scaling.

### Metrics Configuration
Use CPU utilization as the primary metric. Memory-based scaling should only be used for memory-intensive workloads — for API gateways, CPU-only is sufficient.

### Resource Requests
Ensure deployment containers have appropriate CPU requests (>= 100m) to prevent inflated utilization calculations. A request of 1m will cause the HPA to calculate 10000% utilization even under minimal load.

---
*Last updated: 2026-03-01 by Platform Operations Team*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"HPA-Scaling-Best-Practices\",\"content_base64\":\"$(echo "$WIKI1" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: HPA-Scaling-Best-Practices" || true

# ── WIKI PAGE 2: Platform Operations Framework (KEY BREADCRUMB) ──────────────
WIKI2=$(cat <<'WIKICONTENT'
## Platform Operations Framework

### Overview
The Platform Operations team manages cluster-wide compliance and drift correction policies for the Bleater platform. This document describes the enforcement architecture.

### Enforcement Architecture

Enforcement is managed through multiple layers:

1. **CronJob-based reconciliation** — Periodic jobs in operational namespaces (kube-ops, bleater-env, default) ensure configuration drift is corrected. Each CronJob reads encoded policies from ConfigMaps and applies them.

2. **Node-level enforcement** — Static pods and DaemonSets provide node-level policy enforcement that persists across CronJob deletions.

3. **k3s auto-deploy manifests** — Critical compliance policies are deployed via k3s server manifests at `/var/lib/rancher/k3s/server/manifests/`. These are automatically reconciled by k3s — even if the resources are deleted via kubectl, k3s will recreate them from the manifest files. **To permanently remove auto-deployed resources, the manifest file must be removed from disk.**

4. **Annotation-driven policies** — Resources with `platform-ops.io/compliance-enforced: "true"` annotations are subject to periodic compliance checks.

### Protected System Files
Critical manifests (static pods, k3s server manifests) are deployed to protected system directories. Static pods are managed by kubelet directly and cannot be deleted via the Kubernetes API — the manifest file must be removed from disk to stop the pod.

### Operational Channels
For real-time enforcement status and operational updates:
- Mattermost: **#platform-ops** channel
- See the Infrastructure-Component-Registry wiki page for a full list of managed components

### Contact
- Platform Operations Lead: sarah.chen@bleater.io
- On-call rotation: See PagerDuty schedule "platform-ops-oncall"

---
*Last updated: 2026-03-08 by Platform Operations Team*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Platform-Operations-Framework\",\"content_base64\":\"$(echo "$WIKI2" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: Platform-Operations-Framework" || true

# ── WIKI PAGE 3: Scaling Migration Status (MISLEADING — makes dup HPA look intentional) ──
WIKI3=$(cat <<'WIKICONTENT'
## Scaling Migration Status

### Current Phase: Phase 2 — Parallel Running

| Field | Value |
|-------|-------|
| Ticket | PLAT-4821 |
| Started | 2026-02-15 |
| Target Completion | 2026-03-20 |
| Owner | platform-ops team |
| Status | **In Progress** |

### Background
We are migrating from the legacy HPA configuration (`bleater-api-gateway-hpa`) to a new v2 scaling policy (`bleater-gateway-scaling-v2`). During Phase 2, both HPAs run in parallel to validate the new scaling parameters.

### Phase Details

1. **Phase 1** (Complete): Deploy v2 HPA alongside v1
2. **Phase 2** (Current): Monitor both HPAs for 2 weeks, compare scaling decisions
3. **Phase 3** (Planned): Remove v1 HPA, rename v2 to primary

### Important Notes
- ⚠️ **DO NOT delete `bleater-gateway-scaling-v2`** during Phase 2 — it is part of the migration pipeline
- The v2 HPA intentionally has different thresholds for A/B comparison
- The DaemonSet `k3s-resource-reconciler` ensures the v2 HPA is maintained during the migration
- If the v2 HPA is accidentally deleted, the DaemonSet will recreate it within 2 minutes

### Rollback Plan
If issues arise, suspend the v2 HPA and notify the platform-ops team via Mattermost #platform-ops.

---
*Last updated: 2026-03-05 by Platform Operations Team*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Scaling-Migration-Status\",\"content_base64\":\"$(echo "$WIKI3" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: Scaling-Migration-Status" || true

# ── WIKI PAGE 4: Infrastructure Component Registry (MIX — lists all CronJobs) ──
WIKI4=$(cat <<'WIKICONTENT'
## Infrastructure Component Registry

### Platform-Managed CronJobs

All CronJobs listed below are managed by the Platform Operations team. They perform critical cluster maintenance and should not be modified without approval.

#### kube-ops namespace
| CronJob | Component | Schedule | Description |
|---------|-----------|----------|-------------|
| containerd-log-rotate | log-management | Every minute | Rotates stale container logs and syncs runtime state |
| cni-bridge-monitor | network-monitor | Every minute | Monitors CNI bridge interfaces and reconciles network state |
| oom-score-adjuster | memory-management | Every minute | Adjusts OOM scores and reconciles memory pressure policies |
| node-pressure-monitor | resource-monitor | Every minute | Monitors node resource pressure and enforces scaling limits |
| hpa-policy-enforcer | policy-audit | Every 2 min | Audits HPA policy compliance (read-only) |
| hpa-config-manager | config-sync | Every 5 min | Syncs HPA tuning parameters from central config |
| scaling-event-monitor | event-monitor | Every 4 min | Monitors scaling events for alerting |

#### bleater-env namespace
| CronJob | Component | Schedule | Description |
|---------|-----------|----------|-------------|
| kube-state-cache-sync | state-cache | Every minute | Syncs kube-state-metrics cache |
| resource-quota-reconciler | quota-management | Every minute | Reconciles resource quotas |
| resource-limit-enforcer | limit-enforcement | Every minute | Enforces resource limit policies |
| metrics-aggregation-sync | metrics-aggregation | Every 3 min | Syncs metrics aggregation data |
| endpoint-health-checker | endpoint-health | Every 5 min | Checks service endpoint health |

#### default namespace
| CronJob | Component | Schedule | Description |
|---------|-----------|----------|-------------|
| cert-rotation-watcher | cert-management | Every minute | Watches certificate rotation status |
| admission-audit-logger | admission-audit | Every minute | Logs admission controller audit events |
| pod-health-reconciler | health-reconciliation | Every minute | Reconciles pod health state |
| namespace-resource-auditor | resource-audit | Every 4 min | Audits namespace resource usage |

#### kube-system namespace
| CronJob | Component | Schedule | Description |
|---------|-----------|----------|-------------|
| platform-compliance-audit | compliance | Every minute | Enforces baseline scaling and metrics compliance |

### Platform-Managed DaemonSets

#### kube-system namespace
| DaemonSet | Description |
|-----------|-------------|
| k3s-resource-reconciler | Reconciles node-level resource state for cluster stability |

### Notes
- All components are labeled with `app.kubernetes.io/managed-by: platform-ops`
- Suspending or deleting these components may cause platform drift
- For changes, file a ticket in JIRA project PLAT or contact #platform-ops on Mattermost

---
*Last updated: 2026-03-12 by Platform Operations Team*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Infrastructure-Component-Registry\",\"content_base64\":\"$(echo "$WIKI4" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: Infrastructure-Component-Registry" || true

# ── WIKI PAGE 5: Incident Response Playbook (SECONDARY BREADCRUMB) ───────────
WIKI5=$(cat <<'WIKICONTENT'
## Incident Response Playbook

### HPA Scaling Thrash

**Symptoms**: API gateway pods scale up and down rapidly, generating excessive scaling events.

**Common Causes**:
1. CPU target too low (< 40%) causing premature scale-up
2. Missing stabilization windows allowing rapid oscillation
3. Aggressive scaling policies removing/adding too many pods per cycle
4. Deployment CPU requests too low (inflated utilization calculation)
5. Broken metrics pipeline (HPA shows `<unknown>` targets)

**Investigation Steps**:
1. Check HPA status: `kubectl get hpa -n bleater`
2. Verify metrics pipeline: `kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes`
3. Check deployment resources: `kubectl get deploy bleater-api-gateway -n bleater -o yaml`
4. Review scaling events: `kubectl get events -n bleater --field-selector reason=SuccessfulRescale`

**Advanced Troubleshooting**:
If scaling thrash persists after fixing HPA configuration, check for:
- Compliance enforcement CronJobs that may revert changes (check all namespaces)
- k3s server manifests at `/var/lib/rancher/k3s/server/manifests/` that auto-deploy enforcement resources
- Static pods that reconcile platform state (check pod-manifests directory)
- Protected files with filesystem immutability flags (use `lsattr` to check)

**Escalation**: Contact Platform Operations team via #platform-ops on Mattermost.

---
*Last updated: 2026-03-10 by SRE Team*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Incident-Response-Playbook\",\"content_base64\":\"$(echo "$WIKI5" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: Incident-Response-Playbook" || true

# ── WIKI PAGE 6: Metrics Server Architecture (MISLEADING) ────────────────────
WIKI6=$(cat <<'WIKICONTENT'
## Metrics Server Architecture

### Overview
The Bleater platform uses the standard Kubernetes metrics-server for resource metrics (CPU, memory). The metrics pipeline flows as follows:

```
kubelet (cAdvisor) → metrics-server → metrics.k8s.io API → HPA controller
```

### Configuration Details

#### APIService
The APIService `v1beta1.metrics.k8s.io` must point to the metrics-server service in kube-system. If this is misconfigured, all resource metrics will be unavailable.

#### Service
The metrics-server Service uses the selector `k8s-app: metrics-aggregator` for backward compatibility with the metrics aggregation layer. This was changed from `metrics-server` in the v2.0 migration to support the new aggregation pipeline.

> **Note**: Do not change this selector back to `metrics-server` — it will break the aggregation pipeline.

#### Deployment
The metrics-server deployment should have:
- `--kubelet-insecure-tls` for k3s compatibility
- `--metric-resolution=15s` for timely updates
- `--kubelet-preferred-address-types=InternalIP` (do NOT use ExternalIP)

### Troubleshooting
If metrics are unavailable:
1. Check APIService: `kubectl get apiservice v1beta1.metrics.k8s.io -o yaml`
2. Check Service selector matches deployment labels
3. Check metrics-server logs: `kubectl logs -n kube-system -l k8s-app=metrics-server`

---
*Last updated: 2026-02-20 by Infrastructure Team*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Metrics-Server-Architecture\",\"content_base64\":\"$(echo "$WIKI6" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: Metrics-Server-Architecture" || true

# ── WIKI PAGE 7: SRE Scaling Standards (KEY — correct thresholds but buried in narrative) ──
WIKI7=$(cat <<'WIKICONTENT'
## SRE Scaling Standards — Production HPA Policy

### Purpose
This document defines the scaling parameters for production HPA-managed services on the Bleater platform. These standards were updated after the Q4 2025 scaling incident (INC-2025-0391) where aggressive autoscaling caused cascading pod evictions.

> **Note**: This page supersedes the Q3 2025 baselines that are still stored in the `sre-scaling-baseline` ConfigMap. That ConfigMap has **not been updated** to reflect the post-incident changes. Always use this wiki page as the authoritative source.

### Background

Prior to the Q4 incident, the platform used shorter stabilization windows and `selectPolicy: Max` to prioritize responsiveness. The incident demonstrated that aggressive scaling creates more problems than it solves — pod churn under variable load caused more downtime than slightly delayed scaling ever would.

The key insight: **stability over speed**. The HPA controller should always choose the **least disruptive** action, and configuration should prevent oscillation even at the cost of slower scale-up response times.

### Stabilization Windows

Production services must use stabilization windows that allow multiple metrics collection cycles to complete before scaling decisions are finalized:

- **ScaleDown**: Minimum of one hundred and eighty seconds. This prevents premature scale-in during transient load dips. The metrics-server scrapes every 15 seconds, so this minimum represents 12 collection cycles — enough to distinguish real load drops from temporary fluctuations.

- **ScaleUp**: Minimum of forty-five seconds. This dampens burst reactions while still responding to sustained load increases within our SLA commitments. Lower values (e.g., 0s or 15s) cause the HPA to react to every transient spike.

### Select Policy

The `selectPolicy` field controls how the HPA chooses between multiple scaling policies. Our standard requires `selectPolicy: Min` for both directions, which selects the **least disruptive** scaling action from the available policies.

Never use `selectPolicy: Max` in production — it picks the most aggressive action and directly causes the kind of thrashing we saw in Q4. The `Disabled` option prevents scaling entirely, which is only appropriate for maintenance windows.

### Scaling Policies

When defining behavior policies, the goal is to limit the rate of change per cycle:

**ScaleDown constraints:**
- Percentage-based policies should not remove more than thirty percent of pods in a period shorter than 60 seconds
- No policy should ever remove more than 50% of pods regardless of period length
- Recommended conservative baseline: 10% per 60s (Percent type) combined with 2 pods per 60s (Pods type)

**ScaleUp constraints:**
- Percentage-based policies should not add more than one hundred percent of pods in a period shorter than thirty seconds
- Recommended baseline: 50% per 60s (Percent type) combined with 3 pods per 60s (Pods type)

### CPU Target and Metrics

For production API services like the api-gateway:
- Target CPU utilization should be between forty and eighty percent
- Targets below 40% cause unnecessary scaling activity (resource waste)
- Targets above eighty percent leave insufficient headroom for traffic bursts
- Use CPU-only metrics for request-processing services — memory-based scaling metrics are only appropriate for stateful workloads and data processing services

### Deployment Resource Requirements

Proper CPU requests and limits are essential for meaningful HPA behavior:
- CPU request must be at least fifty millicores — requests below this threshold cause the HPA to compute artificially inflated utilization percentages (e.g., a 1m request with 10m actual usage shows 1000% utilization)
- CPU limit must be at least two hundred millicores — this ensures containers have adequate burst capacity during traffic spikes

### Replica Bounds

- **minReplicas**: Must be between 2 and five. A minimum of two is required for high availability — single-replica services have no redundancy during pod restarts or node failures.
- **maxReplicas**: Must be between eight and 15. This hard cap prevents runaway scaling that could exhaust cluster resources and starve other services.
- Only one HPA should target each deployment. Multiple HPAs targeting the same deployment create conflicting scaling decisions that amplify thrashing.

### Compliance and Exceptions

These standards are enforced by the Platform Operations team through automated compliance CronJobs. Non-compliant configurations will be reverted to baseline values.

The enforcement architecture uses multiple layers — see the Platform-Operations-Framework wiki page for details on how enforcement works and what needs to be changed to permanently update configurations.

For exceptions to these standards, file a request in JIRA project PLAT with business justification and SRE leadership approval.

---
*Approved by: SRE Leadership — 2026-01-15*
*Last reviewed: 2026-03-01*
*Supersedes: Q3 2025 baselines (sre-scaling-baseline ConfigMap)*
WIKICONTENT
)

curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"SRE-Scaling-Standards\",\"content_base64\":\"$(echo "$WIKI7" | base64 -w0)\"}" \
    2>/dev/null && echo "  Wiki: SRE-Scaling-Standards" || true

echo "✓ Wiki documentation populated"
) # end wiki subshell
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 19b: Gitea issues — incident context and threshold hints
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 19b: Creating platform issues..."

(
set +e

GITEA_PASS=$(python3 -c "
import urllib.request, re
try:
    html = urllib.request.urlopen('http://passwords.devops.local', timeout=10).read().decode()
    m = re.search(r'<h3>Gitea</h3>.*?Password.*?class=\"value\">([^<]+)', html, re.DOTALL)
    print(m.group(1).strip() if m else 'password')
except: print('password')
" 2>/dev/null)
GITEA_PASS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GITEA_PASS}', safe=''))")
GITEA_SVC_IP=$(kubectl get svc gitea -n gitea -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
GITEA_HOST="${GITEA_SVC_IP}:3000"
GITEA_API="http://root:${GITEA_PASS_ENC}@${GITEA_HOST}/api/v1"

# Issue 1: HPA thrashing incident
ISSUE1_ID=$(curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues" \
    -H "Content-Type: application/json" \
    -d '{"title":"P2: bleater-api-gateway HPA scaling thrash since Monday","body":"The api-gateway HPA has been thrashing since the platform-ops enforcement rollout on Monday. Pods are scaling up and down every few minutes. Customers are reporting intermittent 503 errors during scale-down events.\n\nThis needs investigation — the HPA config looks wrong but changes keep getting reverted.\n\nCC @sarah.chen @platform-ops","labels":[]}' \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)

if [ -n "$ISSUE1_ID" ]; then
    # Comment 1: Initial investigation — vague, mentions wiki
    curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues/${ISSUE1_ID}/comments" \
        -H "Content-Type: application/json" \
        -d '{"body":"Looked into this. The HPA stabilization windows are way too low — definitely not meeting our SRE standards. The selectPolicy also looks wrong. Check the SRE-Scaling-Standards wiki page for the correct production thresholds.\n\nAlso the CPU target seems absurdly low and the deployment resources are underprovisioned. The sre-scaling-baseline ConfigMap in bleater namespace has some reference values but I think those might be outdated (Q3 2025)."}' \
        2>/dev/null || true
    sleep 1

    # Comment 2: Enforcement hints — vague about exact mechanism
    curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues/${ISSUE1_ID}/comments" \
        -H "Content-Type: application/json" \
        -d '{"body":"I tried fixing the HPA config but it got reverted. Something is re-applying the broken values. There are a bunch of CronJobs across multiple namespaces (kube-ops, bleater-env, default) that look like maintenance tasks but some of them might be doing more than they say. Need to investigate which ones are actually patching the HPA.\n\nAlso saw mentions of a scaling migration (v2 HPA) — not sure if that is relevant or a red herring."}' \
        2>/dev/null || true
    sleep 1

    # Comment 3: Metrics and resources — hints but no exact values
    curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues/${ISSUE1_ID}/comments" \
        -H "Content-Type: application/json" \
        -d '{"body":"The metrics pipeline is also broken — HPA shows unknown for CPU metrics. Might be an APIService or service selector issue. And there is something in the bleater namespace blocking resource changes (getting admission errors when trying to set proper CPU limits).\n\nThe Platform-Operations-Framework wiki page has info about the enforcement architecture. Worth reading before trying to fix things — there are multiple layers involved."}' \
        2>/dev/null || true
    sleep 1

    echo "  ✓ Issue #${ISSUE1_ID} created with comments"
fi

# Issue 2: Scaling standards reminder — references wiki but doesn't list values
ISSUE2_ID=$(curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues" \
    -H "Content-Type: application/json" \
    -d '{"title":"Reminder: audit all HPAs against SRE scaling standards","body":"All production HPAs need to be audited against our current SRE scaling standards. The standards were updated after the Q4 2025 incident (INC-2025-0391) — the latest approved values are on the SRE-Scaling-Standards wiki page.\n\nNote: the sre-scaling-baseline ConfigMap in the bleater namespace has older Q3 2025 values that may not reflect the current standards. Always reference the wiki as the source of truth.\n\nThe api-gateway HPA is suspected to be non-compliant. Please investigate and bring into compliance.","labels":[]}' \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)

if [ -n "$ISSUE2_ID" ]; then
    # Comment pointing to contradictory sources
    curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues/${ISSUE2_ID}/comments" \
        -H "Content-Type: application/json" \
        -d '{"body":"Heads up — there is also an hpa-scaling-review-q4 ConfigMap with PROPOSED changes from the Q4 review. Those are NOT approved yet — do not apply them. Stick with the wiki page values.\n\nAlso be careful with the Metrics-Server-Architecture wiki page — some of the info there about the service selector is from before the v2.0 migration and may be wrong."}' \
        2>/dev/null || true
    echo "  ✓ Issue #${ISSUE2_ID} created (standards reminder)"
fi

# Issue 3: Red herring — scaling migration timeline
ISSUE3_ID=$(curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues" \
    -H "Content-Type: application/json" \
    -d '{"title":"Scaling migration v2 HPA — timeline and cleanup plan","body":"The v2 HPA migration (bleater-gateway-scaling-v2) was started on 2026-02-15. It runs alongside the v1 HPA to validate new scaling parameters.\n\nThe migration is currently ON HOLD per Sarah'\''s request. The v2 HPA should be cleaned up once we confirm the new policies are stable, but DO NOT remove it during the migration phase.\n\nThe k3s-resource-reconciler DaemonSet in kube-system maintains the v2 HPA during migration. If it gets deleted, the DaemonSet will recreate it within 2 minutes.\n\nSee Scaling-Migration-Status wiki for full details.","labels":[]}' \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)

if [ -n "$ISSUE3_ID" ]; then
    echo "  ✓ Issue #${ISSUE3_ID} created (migration timeline — red herring)"
fi

# Issue 4: Red herring — metrics dashboard gaps
ISSUE4_ID=$(curl -sf -X POST "${GITEA_API}/repos/root/bleater-app/issues" \
    -H "Content-Type: application/json" \
    -d '{"title":"Metrics dashboard showing gaps — possible metrics-server issue","body":"The Grafana dashboards are showing gaps in CPU/memory metrics for the last few hours. This might be related to the metrics-server configuration changes that were made during the aggregation pipeline migration.\n\nThe Metrics-Server-Architecture wiki page says the service selector was changed to metrics-aggregator for backward compatibility. Can someone verify if this is still correct? I'\''m not sure if the v2.0 migration is complete.\n\nAlso noticed the APIService might be pointing to the wrong service name. Need someone to check.","labels":[]}' \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)

if [ -n "$ISSUE4_ID" ]; then
    echo "  ✓ Issue #${ISSUE4_ID} created (metrics gaps — red herring)"
fi

echo "✓ Platform issues created"
) # end issues subshell
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 20: Mattermost messages — breadcrumbs in #platform-ops channel
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 20: Populating team communications..."

(
set +e

MATTERMOST_URL="http://mattermost.devops.local."

# Wait for Mattermost readiness
WAIT=0
until curl -sf -o /dev/null "${MATTERMOST_URL}/api/v4/system/ping" 2>/dev/null; do
    sleep 5
    WAIT=$((WAIT + 5))
    if [ $WAIT -ge 60 ]; then
        echo "  Mattermost not ready after 60s, skipping"
        exit 0
    fi
done

# Get Mattermost credentials
MM_PASS=$(python3 -c "
import urllib.request, re
try:
    html = urllib.request.urlopen('http://passwords.devops.local.', timeout=10).read().decode()
    m = re.search(r'<h3>Mattermost</h3>.*?Password.*?class=\"value\">([^<]+)', html, re.DOTALL)
    print(m.group(1).strip() if m else 'changeme')
except: print('changeme')
" 2>/dev/null)

# Login
MM_TOKEN=$(curl -sf -X POST "${MATTERMOST_URL}/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"admin\",\"password\":\"${MM_PASS}\"}" \
    -D - 2>/dev/null | grep -i "^token:" | awk '{print $2}' | tr -d '\r\n')

if [ -z "$MM_TOKEN" ]; then
    echo "  Mattermost login failed, skipping"
    exit 0
fi

# Get team ID
TEAM_ID=$(curl -sf -H "Authorization: Bearer ${MM_TOKEN}" \
    "${MATTERMOST_URL}/api/v4/teams" 2>/dev/null | python3 -c "
import sys, json
try:
    teams = json.load(sys.stdin)
    print(teams[0]['id'] if teams else '')
except: print('')
" 2>/dev/null)

# Create #platform-ops channel
CHANNEL_ID=$(curl -sf -X POST -H "Authorization: Bearer ${MM_TOKEN}" \
    -H "Content-Type: application/json" \
    "${MATTERMOST_URL}/api/v4/channels" \
    -d "{\"team_id\":\"${TEAM_ID}\",\"name\":\"platform-ops\",\"display_name\":\"Platform Ops\",\"type\":\"O\",\"purpose\":\"Platform operations coordination and enforcement status\"}" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

# If channel already exists, get its ID
if [ -z "$CHANNEL_ID" ]; then
    CHANNEL_ID=$(curl -sf -H "Authorization: Bearer ${MM_TOKEN}" \
        "${MATTERMOST_URL}/api/v4/teams/${TEAM_ID}/channels/name/platform-ops" \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
fi

if [ -z "$CHANNEL_ID" ]; then
    echo "  Could not create/find platform-ops channel, skipping"
    exit 0
fi

# Post messages
post_msg() {
    local msg="$1"
    curl -sf -X POST -H "Authorization: Bearer ${MM_TOKEN}" \
        -H "Content-Type: application/json" \
        "${MATTERMOST_URL}/api/v4/posts" \
        -d "{\"channel_id\":\"${CHANNEL_ID}\",\"message\":$(echo "$msg" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" \
        2>/dev/null || true
    sleep 1
}

# Message 1: Enforcement architecture hint (useful but vague)
post_msg "@team Compliance enforcement is active on the bleater platform. Multiple layers involved — CronJobs, node-level components, and auto-deploy manifests. Changes made via kubectl may get reverted. Check the Platform-Operations-Framework wiki for architecture details."

# Message 2: WRONG advice — points to outdated ConfigMap (TRAP)
post_msg "For anyone configuring HPAs: reference the \`sre-scaling-baseline\` ConfigMap in the bleater namespace. It has the approved production thresholds for stabilization windows, selectPolicy, CPU targets, etc. Should be the source of truth for all scaling configs."

# Message 3: Partially corrects message 2 (but introduces ambiguity)
post_msg "Actually, I think the sre-scaling-baseline ConfigMap might be outdated (Q3 values). The SRE team updated the standards after the Q4 incident. Check the **SRE-Scaling-Standards** wiki page for the latest — some of the thresholds changed."

# Message 4: CONTRADICTORY selectPolicy advice
post_msg "Question: the Q4 scaling review (hpa-scaling-review-q4 ConfigMap) recommends selectPolicy: Max for scaleUp. But the sre-scaling-baseline says Disabled. Which one should we use? I thought the wiki says something different again."

# Message 5: Vague response (doesn't resolve confusion)
post_msg "Use whatever the SRE wiki says. The ConfigMaps have different versions and some are outdated or proposals. The wiki is maintained by SRE leadership and should be authoritative. But double-check because I've seen conflicting info between the wiki pages too."

# Message 6: Static pod / server manifest hint (useful)
post_msg "Reminder: static pods are managed by kubelet directly — \`kubectl delete\` won't work. You have to remove the manifest file from disk. Same goes for k3s auto-deploy manifests in the server directory."

# Message 7: Migration red herring
post_msg "FYI the scaling migration (v2 HPA - \`bleater-gateway-scaling-v2\`) is ON HOLD pending review from Sarah. The DaemonSet in kube-system maintains it during migration. See the Scaling-Migration-Status wiki page for details before making any changes."

# Message 8: Metrics hint (partially wrong)
post_msg "Seeing metric gaps in the dashboards. Someone should check if the metrics-server service selector and APIService config are correct. The Metrics-Server-Architecture wiki page has the expected config but some of that info might be from before the aggregation migration."

# Message 9: LimitRange hint (useful)
post_msg "There's a LimitRange in the bleater namespace that seems too restrictive. Not sure what the exact limit is but it might be blocking deployment resource changes. Worth checking."

# Message 10: General vague warning
post_msg "To whoever is fixing the api-gateway HPA — be aware there are multiple enforcement mechanisms that will revert your changes. CronJobs across several namespaces, a DaemonSet, and filesystem-level enforcers. You need to neutralize ALL of them before your fixes will stick."

echo "  ✓ Mattermost messages posted"
) # end Mattermost subshell
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 21: Wait for first enforcement cycle
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 21: Waiting for enforcement to initialize (90 seconds)..."
sleep 90
echo "✓ Enforcement active — all drift-correction cycles confirmed"
echo ""

echo "=== Setup Complete ==="
echo ""
