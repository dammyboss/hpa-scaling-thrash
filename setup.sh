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
IMAGE="bitnami/kubectl:1.31.0"

echo "=== Setting up HPA Scaling Thrash Scenario ==="
echo ""

# ── Step 1: Metrics-server check ────────────────────────────────────────────
echo "Step 1: Ensuring metrics-server is running..."

if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "  Metrics-server not found, this may cause issues"
else
    echo "✓ Metrics-server is available"
fi
echo ""

# ── Step 2: Wait for bleater-api-gateway ────────────────────────────────────
echo "Step 2: Waiting for bleater-api-gateway deployment..."

kubectl wait --for=condition=available --timeout=120s \
    deployment/bleater-api-gateway -n "$NS" 2>/dev/null || \
    echo "  Note: bleater-api-gateway may still be starting"

echo "✓ bleater-api-gateway deployment ready"
echo ""

# ── Step 3: ConfigMaps ──────────────────────────────────────────────────────
echo "Step 3: Creating policy ConfigMap and decoy ConfigMap..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-policy-config
  namespace: $NS
data:
  scaledown_window: "10"
  scaleup_window: "0"
  scaledown_percent: "60"
  scaledown_period: "10"
  scaleup_percent: "150"
  scaleup_period: "10"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-tuning-params
  namespace: $NS
data:
  target_cpu: "50"
  min_replicas: "3"
  max_replicas: "12"
  cooldown_period: "300"
  scale_factor: "1.5"
EOF

echo "✓ ConfigMaps created"
echo ""

# ── Step 4: HPA ─────────────────────────────────────────────────────────────
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
  minReplicas: 3
  maxReplicas: 12
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 10
      policies:
      - type: Percent
        value: 60
        periodSeconds: 10
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 150
        periodSeconds: 10
      selectPolicy: Max
EOF

echo "✓ HPA created"
echo ""

# ── Step 5: Degrade metrics-server ──────────────────────────────────────────
echo "Step 5: Adjusting cluster telemetry configuration..."

kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=ExternalIP"}]' \
  2>/dev/null || echo "  Note: telemetry config already adjusted"

echo "✓ Telemetry configuration adjusted"
echo ""

# ── Step 6: Create kube-ops namespace ───────────────────────────────────────
echo "Step 6: Creating kube-ops namespace..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
EOF

echo "✓ kube-ops namespace ready"
echo ""

# ── Step 7: RBAC — ubuntu user gets scoped access to kube-ops ───────────────
echo "Step 7: Configuring RBAC for platform operator..."

# ServiceAccount that CronJob pods run as (needs to patch HPA in bleater)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-reconciler
  namespace: $OPS_NS
---
# ClusterRole: patch HPA in bleater, read metrics
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hpa-reconciler
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "patch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "patch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hpa-reconciler-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hpa-reconciler
subjects:
- kind: ServiceAccount
  name: platform-reconciler
  namespace: $OPS_NS
---
# Role: ubuntu user can list/get/delete CronJobs in kube-ops (for debugging)
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
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-ops-cronjob-manager
  namespace: $OPS_NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ops-cronjob-manager
subjects:
- kind: User
  name: system:serviceaccount:default:ubuntu-user
  apiGroup: rbac.authorization.k8s.io
EOF

echo "✓ RBAC configured"
echo ""

# ── Step 8: Real enforcer CronJobs in kube-ops ──────────────────────────────
echo "Step 8: Installing platform reconciliation CronJobs..."

# ── REAL ENFORCER #1 ── scaleDown.stabilizationWindowSeconds → 10
# Named to blend in with system-level log management components
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
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}' \
                && sleep 20 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}' \
                && sleep 20 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}'
EOF

# ── REAL ENFORCER #2 ── scaleUp.stabilizationWindowSeconds → 0
# Named to blend in with CNI networking components
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
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}' \
                && sleep 18 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}' \
                && sleep 18 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}'
EOF

# ── REAL ENFORCER #3 ── scaleDown.policies → {60%, 10s}
# Named to blend in with OOM/memory management components
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
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10}]}}}}' \
                && sleep 22 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10}]}}}}' \
                && sleep 22 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10}]}}}}'
EOF

# ── REAL ENFORCER #4 ── scaleUp.policies → {150%, 10s}
# Named to blend in with node pressure / resource monitoring
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
      template:
        spec:
          serviceAccountName: platform-reconciler
          restartPolicy: OnFailure
          containers:
          - name: reconciler
            image: $IMAGE
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' \
                && sleep 25 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' \
                && sleep 25 && \
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}'
EOF

echo "✓ Enforcer CronJobs installed in kube-ops"
echo ""

# ── Step 9: Decoy CronJobs in kube-ops ──────────────────────────────────────
echo "Step 9: Installing platform monitoring CronJobs (decoys)..."

# DECOY #1 — reads hpa-policy-config ConfigMap and logs; does NOT patch HPA
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
              kubectl get configmap hpa-policy-config -n bleater \
                -o jsonpath='{.data}' 2>/dev/null || true
EOF

# DECOY #2 — patches the hpa-tuning-params ConfigMap (not the HPA itself)
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
              kubectl patch configmap hpa-tuning-params -n bleater --type=merge \
                -p '{"data":{"target_cpu":"50","min_replicas":"3","max_replicas":"12","cooldown_period":"300","scale_factor":"1.5"}}' \
                2>/dev/null || true
EOF

# DECOY #3 — watches scaling events, logs only
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
              kubectl get hpa bleater-api-gateway-hpa -n bleater 2>/dev/null || true
EOF

echo "✓ Decoy CronJobs installed in kube-ops"
echo ""

# ── Step 10: sudo — scoped, no process killing hints ────────────────────────
echo "Step 10: Configuring ubuntu user sudo permissions..."

cat > /etc/sudoers.d/ubuntu-devops << 'SUDOERS'
# DevOps operator permissions for bleater platform management
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/journalctl
SUDOERS

chmod 440 /etc/sudoers.d/ubuntu-devops
echo "✓ sudo configured"
echo ""

# ── Step 11: Wait for first CronJob cycle to fire ───────────────────────────
echo "Step 11: Waiting for enforcement to initialize (75 seconds)..."
# CronJobs fire on the minute boundary; give up to 75s to ensure at least
# one complete cycle has run and HPA values are confirmed bad.
sleep 75
echo "✓ Enforcement active — HPA values confirmed degraded"
echo ""

echo "=== Setup Complete ==="
echo ""
