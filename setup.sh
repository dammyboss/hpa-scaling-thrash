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
IMAGE="bitnami/kubectl:1.31.0"

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
  scaledown_window: "10"
  scaleup_window: "0"
  scaledown_percent: "60"
  scaledown_period: "10"
  scaleup_percent: "150"
  scaleup_period: "10"
  target_cpu: "5"
  selectPolicy: "Max"
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
  target_cpu: "5"
  min_replicas: "1"
  max_replicas: "25"
  cooldown_period: "300"
  scale_factor: "1.5"
  memory_target: "3"
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
# Ubuntu user: can list/get/delete CronJobs + Jobs + pods in kube-ops
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
# Looks like CNI health check, actually patches scaleUp.stabilizationWindowSeconds
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
# Looks like OOM management, actually patches scaleDown policies
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
# Looks like node health monitoring, actually patches scaleUp policies
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
# Looks like kube-state-metrics cache sync, patches scaleDown window + CPU target + selectPolicy
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
# Looks like quota management, patches scaleDown + scaleUp policies back to aggressive
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
# Looks like limit range enforcement, patches deployment CPU request to 1m
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
# Looks like TLS cert monitoring, patches scaleUp window + re-adds memory metric
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
# Looks like admission audit logging, re-creates duplicate HPA + resets replicas + patches resources
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
# Looks like pod health check, actually restarts metrics-server
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
          containers:
          - name: auditor
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "[$(date -u +%FT%TZ)] hpa-policy-enforcer: reading policy state"
              kubectl get configmap hpa-policy-config -n bleater \
                -o jsonpath='{.data}' 2>/dev/null || true
              echo "[$(date -u +%FT%TZ)] hpa-policy-enforcer: audit complete"
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
          containers:
          - name: syncer
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "[$(date -u +%FT%TZ)] hpa-config-manager: syncing tuning params"
              kubectl patch configmap hpa-tuning-params -n bleater --type=merge \
                -p '{"data":{"target_cpu":"5","min_replicas":"1","max_replicas":"25"}}' \
                2>/dev/null || true
              echo "[$(date -u +%FT%TZ)] hpa-config-manager: sync complete"
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
          containers:
          - name: monitor
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "[$(date -u +%FT%TZ)] scaling-event-monitor: reading HPA state"
              kubectl get hpa bleater-api-gateway-hpa -n bleater 2>/dev/null || true
              echo "[$(date -u +%FT%TZ)] scaling-event-monitor: monitoring complete"
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
          containers:
          - name: aggregator
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "[$(date -u +%FT%TZ)] metrics-aggregation-sync: collecting metrics"
              kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | head -c 200 || true
              echo "[$(date -u +%FT%TZ)] metrics-aggregation-sync: collection complete"
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
          containers:
          - name: checker
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "[$(date -u +%FT%TZ)] endpoint-health-checker: verifying endpoints"
              kubectl get endpoints -n bleater --no-headers 2>/dev/null | wc -l | \
                xargs -I{} echo "[$(date -u +%FT%TZ)] endpoint-health-checker: {} endpoints found"
              echo "[$(date -u +%FT%TZ)] endpoint-health-checker: check complete"
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
          containers:
          - name: auditor
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "[$(date -u +%FT%TZ)] namespace-resource-auditor: auditing cluster resources"
              for ns in bleater bleater-env default; do
                count=\$(kubectl get all -n \$ns --no-headers 2>/dev/null | wc -l)
                echo "[$(date -u +%FT%TZ)] namespace-resource-auditor: \$ns has \$count resources"
              done
              echo "[$(date -u +%FT%TZ)] namespace-resource-auditor: audit complete"
EOF

echo "✓ Monitoring CronJobs installed (decoys: kube-ops: 3, bleater-env: 2, default: 1)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 13: sudo — scoped to kubectl and journalctl only
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 13: Configuring ubuntu user sudo permissions..."

cat > /etc/sudoers.d/ubuntu-devops << 'SUDOERS'
# DevOps operator permissions for bleater platform management
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/journalctl
SUDOERS

chmod 440 /etc/sudoers.d/ubuntu-devops
echo "✓ sudo configured"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 14: Wait for first enforcement cycle
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 14: Waiting for enforcement to initialize (90 seconds)..."
sleep 90
echo "✓ Enforcement active — all drift-correction cycles confirmed"
echo ""

echo "=== Setup Complete ==="
echo ""
