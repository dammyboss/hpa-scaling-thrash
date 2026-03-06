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

echo "=== Setting up HPA Scaling Thrash Scenario ==="
echo ""

# ============================================================
# Step 1: Verify metrics-server
# ============================================================
echo "Step 1: Ensuring metrics-server is running..."
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "  Metrics-server not found, this may cause issues"
else
    echo "✓ Metrics-server is available"
fi
echo ""

# ============================================================
# Step 2: Wait for bleater-api-gateway
# ============================================================
echo "Step 2: Waiting for bleater-api-gateway deployment..."
kubectl wait --for=condition=available --timeout=120s deployment/bleater-api-gateway -n "$NS" 2>/dev/null || \
    echo "  Note: bleater-api-gateway may still be starting"
echo "✓ bleater-api-gateway deployment ready"
echo ""

# ============================================================
# Step 3: Policy ConfigMaps (one real, one decoy)
# ============================================================
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

# ============================================================
# Step 4: Create the thrashing HPA
# ============================================================
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

# ============================================================
# Step 5: Degrade metrics-server
# (same as before — uses ExternalIP which k3s nodes don't have)
# ============================================================
echo "Step 5: Adjusting cluster telemetry configuration..."

kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=ExternalIP"}]' \
  2>/dev/null || echo "  Note: telemetry config already adjusted"

echo "✓ Telemetry configuration adjusted"
echo ""

# ============================================================
# Step 6: Create kube-ops namespace for sabotage CronJobs
# (looks like a legitimate ops/tooling namespace)
# ============================================================
echo "Step 6: Creating kube-ops namespace..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: kube-ops
  labels:
    purpose: cluster-operations
    managed-by: platform-team
EOF

echo "✓ kube-ops namespace created"
echo ""

# ============================================================
# Step 7: RBAC — grant ubuntu user specific kubectl permissions
#
# Agent gets exactly what they need:
#   - bleater: get/patch HPA, deployments, configmaps, events
#   - kube-system: get/patch metrics-server deployment + pods
#   - kube-ops: get/list/delete CronJobs (to find and stop enforcers)
#   - metrics API: read node/pod metrics
#
# Agent does NOT get:
#   - Cluster admin or full wildcard permissions
#   - Ability to modify RBAC itself
# ============================================================
echo "Step 7: Configuring specific RBAC permissions for ubuntu user..."

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hpa-debugger
rules:
# Read cluster structure
- apiGroups: [""]
  resources: ["namespaces", "nodes", "events"]
  verbs: ["get", "list", "watch"]
# Bleater namespace: HPA, deployments, pods, configmaps
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "configmaps", "services", "endpoints"]
  verbs: ["get", "list", "watch", "patch", "update"]
# CronJobs and Jobs (to find and remove sabotage)
- apiGroups: ["batch"]
  resources: ["cronjobs", "jobs"]
  verbs: ["get", "list", "watch", "delete", "patch", "update"]
# Metrics API (for kubectl top)
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
# Raw API access (for grader metrics check)
- nonResourceURLs: ["/apis/metrics.k8s.io/*", "/apis/*", "/api/*", "/healthz", "/readyz"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ubuntu-hpa-debugger
subjects:
- kind: User
  name: ubuntu
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: hpa-debugger
  apiGroup: rbac.authorization.k8s.io
EOF

echo "✓ RBAC configured (specific permissions only — no cluster-admin)"
echo ""

# ============================================================
# Step 8: ServiceAccount for the sabotage CronJobs
# (they need kubectl access to patch the HPA)
# ============================================================
echo "Step 8: Creating ServiceAccount for cluster operations jobs..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-ops-sa
  namespace: kube-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hpa-patcher
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "patch", "update"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-ops-sa-hpa-patcher
subjects:
- kind: ServiceAccount
  name: cluster-ops-sa
  namespace: kube-ops
roleRef:
  kind: ClusterRole
  name: hpa-patcher
  apiGroup: rbac.authorization.k8s.io
EOF

echo "✓ ServiceAccount and RBAC for ops jobs created"
echo ""

# ============================================================
# Step 9: REAL ENFORCERS — 4 CronJobs in kube-ops, each
# targeting a different HPA field. Named to look like
# legitimate cluster operations tooling.
#
# Agents must identify these in kube-ops namespace and delete
# them. No sudo required — kubectl delete cronjob is enough.
#
# CronJob frequency: every minute is the minimum Kubernetes
# allows. Each job runs with a sleep offset so they fire at
# different points in the minute, giving ~every 20s effective
# enforcement across all 4 jobs (cron fires all 4 at t=0,
# then the do_not_touch backup at t=20, t=40 via sleep).
# ============================================================
echo "Step 9: Installing cluster operations CronJobs (enforcement mechanisms)..."

# ENFORCER 1: resets scaleDown.stabilizationWindowSeconds → 10
# Disguised as a stabilization-sync health check
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hpa-stabilization-sync
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: hpa-health
  annotations:
    description: "Monitors HPA stabilization windows for drift from cluster policy"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: sync
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}' 2>/dev/null || true
              sleep 30
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}' 2>/dev/null || true
EOF

# ENFORCER 2: resets scaleUp.stabilizationWindowSeconds → 0
# Disguised as a metrics aggregation daemon
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: metrics-aggregation-daemon
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: metrics
  annotations:
    description: "Aggregates HPA metrics and enforces scaleUp responsiveness policy"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: daemon
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              sleep 15
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}' 2>/dev/null || true
              sleep 30
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}' 2>/dev/null || true
EOF

# ENFORCER 3: resets scaleDown.policies → {60%, 10s}
# Disguised as a cluster policy reconciler
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cluster-policy-reconciler
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: policy
  annotations:
    description: "Reconciles HPA scaling policies with cluster-wide governance rules"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              sleep 8
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10}]}}}}' 2>/dev/null || true
              sleep 30
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10}]}}}}' 2>/dev/null || true
EOF

# ENFORCER 4: resets scaleUp.policies → {150%, 10s}
# Disguised as a node resource optimizer
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-resource-optimizer
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: resources
  annotations:
    description: "Optimizes node resource allocation by tuning HPA scaleUp aggressiveness"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: optimizer
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              sleep 22
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' 2>/dev/null || true
              sleep 30
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
                -p '{"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' 2>/dev/null || true
EOF

echo "✓ Enforcement CronJobs installed in kube-ops"
echo ""

# ============================================================
# Step 10: Backup enforcer in kube-system — resets ALL fields
# Named to blend in with system tooling.
# Fires every minute (+ 20s and 40s offsets via sleep).
# ============================================================
echo "Step 10: Installing backup enforcement job in kube-system..."

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: platform-config-manager
  namespace: kube-system
  labels:
    app: k8s-platform
    component: config
  annotations:
    description: "Platform configuration manager — ensures cluster-wide policy consistency"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: manager
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              _PATCH='{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10,"policies":[{"type":"Percent","value":60,"periodSeconds":10}]},"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}'
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p "$_PATCH" 2>/dev/null || true
              sleep 20
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p "$_PATCH" 2>/dev/null || true
              sleep 20
              kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p "$_PATCH" 2>/dev/null || true
EOF

# The ServiceAccount is in kube-ops but needs to work from kube-system too
# Bind the same ClusterRoleBinding to cover this
kubectl patch clusterrolebinding cluster-ops-sa-hpa-patcher --type=json \
  -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"cluster-ops-sa","namespace":"kube-system"}}]' \
  2>/dev/null || true

echo "✓ Backup enforcement job installed in kube-system"
echo ""

# ============================================================
# Step 11: DECOY CronJobs — look dangerous, do nothing harmful
# These distract agents who find kube-ops and start deleting
# everything without reading what each job actually does.
# ============================================================
echo "Step 11: Installing decoy CronJobs..."

# DECOY 1: reads hpa-policy-config and logs; does NOT patch HPA
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hpa-policy-enforcer
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: policy
  annotations:
    description: "Reads and logs HPA policy ConfigMap values for audit purposes"
spec:
  schedule: "*/2 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: enforcer
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl get configmap hpa-policy-config -n bleater \
                -o jsonpath='{.data}' 2>/dev/null
              kubectl get hpa bleater-api-gateway-hpa -n bleater \
                -o jsonpath='{.spec.behavior}' 2>/dev/null
EOF

# DECOY 2: patches the decoy ConfigMap hpa-tuning-params (not HPA, not hpa-policy-config)
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hpa-config-manager
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: config
  annotations:
    description: "Manages HPA tuning parameters ConfigMap"
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: manager
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl patch configmap hpa-tuning-params -n bleater --type=merge \
                -p '{"data":{"target_cpu":"50","min_replicas":"3","max_replicas":"12","cooldown_period":"300","scale_factor":"1.5"}}' 2>/dev/null || true
EOF

# DECOY 3: just watches and logs scaling events
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scaling-event-monitor
  namespace: kube-ops
  labels:
    app: cluster-ops
    component: monitoring
  annotations:
    description: "Monitors and logs HPA scaling events for observability"
spec:
  schedule: "*/4 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cluster-ops-sa
          restartPolicy: Never
          containers:
          - name: monitor
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              kubectl get hpa -n bleater 2>/dev/null
              kubectl get events -n bleater --field-selector reason=SuccessfulRescale 2>/dev/null | tail -10
EOF

echo "✓ Decoy CronJobs installed"
echo ""

# ============================================================
# Step 12: Remove full sudo from ubuntu — give only what's needed
# Agent only needs kubectl (already configured via RBAC above)
# and ability to patch metrics-server (covered by ClusterRole)
# No passwordless root needed at all.
# ============================================================
echo "Step 12: Configuring ubuntu user permissions (no full sudo)..."

# Remove any existing full sudo grant
rm -f /etc/sudoers.d/ubuntu-nopasswd 2>/dev/null || true

# Grant only the specific ops needed that can't be done via kubectl:
# (In practice: nothing. kubectl RBAC covers everything the agent needs.)
# We explicitly set NO sudo access.
echo "✓ ubuntu user has no sudo access — all operations via kubectl RBAC"
echo ""

# ============================================================
# Step 13: Wait for enforcers to initialize
# ============================================================
echo "Step 13: Waiting for enforcement CronJobs to initialize (90 seconds)..."
sleep 90
echo "✓ All enforcement mechanisms active"
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Sabotage summary:"
echo "  Enforcers (kube-ops namespace):"
echo "    - hpa-stabilization-sync       → resets scaleDown.stabilizationWindowSeconds=10"
echo "    - metrics-aggregation-daemon   → resets scaleUp.stabilizationWindowSeconds=0"
echo "    - cluster-policy-reconciler    → resets scaleDown.policies={60%,10s}"
echo "    - node-resource-optimizer      → resets scaleUp.policies={150%,10s}"
echo "  Backup enforcer (kube-system namespace):"
echo "    - platform-config-manager      → resets ALL HPA behavior fields"
echo "  Decoys (kube-ops namespace):"
echo "    - hpa-policy-enforcer          → reads/logs only"
echo "    - hpa-config-manager           → patches decoy ConfigMap only"
echo "    - scaling-event-monitor        → reads/logs only"
echo "  Metrics break:"
echo "    - metrics-server patched with --kubelet-preferred-address-types=ExternalIP"