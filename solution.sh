#!/bin/bash
# Solution: HPA Scaling Thrash Fix (Hard Mode)
# Fixes all breaks across 12 subscores
set -e

NS="bleater"
OPS_NS="kube-ops"
ENV_NS="bleater-env"
DEFAULT_NS="default"
HPA_NAME="bleater-api-gateway-hpa"

echo "=== HPA Scaling Thrash Fix ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Discover and audit all namespaces
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 1: Auditing accessible namespaces..."
for ns in bleater bleater-env default kube-ops kube-system; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "  ✓ $ns accessible"
    fi
done
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Remove the static pod enforcer FIRST
# This is a static pod managed by kubelet — can't be deleted via kubectl.
# Must remove the manifest file from disk to stop it.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2: Checking for static pod enforcers..."

# List static pod manifests
sudo ls /var/lib/rancher/k3s/agent/pod-manifests/ 2>/dev/null || true

# Remove the enforcer manifest
if sudo cat /var/lib/rancher/k3s/agent/pod-manifests/kube-controller-health.yaml 2>/dev/null | grep -q "bleater-api-gateway-hpa"; then
    sudo rm /var/lib/rancher/k3s/agent/pod-manifests/kube-controller-health.yaml
    echo "  ✓ Static pod enforcer manifest removed"
else
    echo "  No enforcer static pod found"
fi

# Wait for kubelet to remove the static pod
sleep 15
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Delete the LimitRange blocking resource fixes
# The LimitRange has max.cpu=20m which prevents setting proper CPU resources.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 3: Checking for blocking LimitRanges..."
kubectl get limitrange -n "$NS" 2>/dev/null || true

kubectl delete limitrange bleater-resource-governance -n "$NS" 2>/dev/null && \
    echo "  ✓ bleater-resource-governance LimitRange deleted" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Fix the APIService for metrics.k8s.io
# The APIService points to 'metrics-aggregator' instead of 'metrics-server'
# Use RBAC-scoped kubectl (no sudo needed — ubuntu-metrics-fixer ClusterRole)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 4: Fixing APIService configuration..."

kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.spec.service}' 2>/dev/null
echo ""

kubectl patch apiservice v1beta1.metrics.k8s.io --type=merge \
  -p '{"spec":{"service":{"name":"metrics-server","namespace":"kube-system"}}}' 2>/dev/null && \
    echo "  ✓ APIService fixed to point to metrics-server" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Discover and delete ALL enforcer CronJobs across all namespaces
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 5: Discovering CronJobs across all namespaces..."
for ns in "$OPS_NS" "$ENV_NS" "$DEFAULT_NS"; do
    echo "--- $ns ---"
    kubectl get cronjobs -n "$ns" -o wide 2>/dev/null || echo "  (no access or no CronJobs)"
done
echo ""

echo "  Inspecting CronJob scripts..."
for ns in "$OPS_NS" "$ENV_NS" "$DEFAULT_NS"; do
    for cm in $(kubectl get configmaps -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        if echo "$cm" | grep -q "script"; then
            echo "--- $ns/$cm ---"
            kubectl get configmap "$cm" -n "$ns" -o jsonpath='{.data.run\.sh}' 2>/dev/null | head -30
            echo ""
        fi
    done
done
echo ""

echo "  Deleting enforcer CronJobs..."

# kube-ops enforcers
for cj in containerd-log-rotate cni-bridge-monitor oom-score-adjuster node-pressure-monitor; do
    kubectl delete cronjob "$cj" -n "$OPS_NS" 2>/dev/null && echo "  ✓ $OPS_NS/$cj deleted" || true
done
kubectl delete jobs --all -n "$OPS_NS" 2>/dev/null || true

# bleater-env enforcers
for cj in kube-state-cache-sync resource-quota-reconciler resource-limit-enforcer; do
    kubectl delete cronjob "$cj" -n "$ENV_NS" 2>/dev/null && echo "  ✓ $ENV_NS/$cj deleted" || true
done
kubectl delete jobs --all -n "$ENV_NS" 2>/dev/null || true

# default enforcers
for cj in cert-rotation-watcher admission-audit-logger pod-health-reconciler; do
    kubectl delete cronjob "$cj" -n "$DEFAULT_NS" 2>/dev/null && echo "  ✓ $DEFAULT_NS/$cj deleted" || true
done
kubectl delete jobs --all -n "$DEFAULT_NS" 2>/dev/null || true

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Delete the DaemonSet enforcer in kube-system that recreates duplicate HPA
# This is disguised as k3s-resource-reconciler — a system-looking DaemonSet.
# Must be deleted BEFORE the duplicate HPA, otherwise it recreates it.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 6: Checking for hidden enforcement in kube-system..."

# List DaemonSets in kube-system and look for suspicious ones
kubectl get daemonsets -n kube-system 2>/dev/null
echo ""

# Delete the DaemonSet enforcer
kubectl delete daemonset k3s-resource-reconciler -n kube-system 2>/dev/null && \
    echo "  ✓ k3s-resource-reconciler DaemonSet deleted" || true

# Clean up its RBAC resources
kubectl delete clusterrolebinding k3s-resource-reconciler 2>/dev/null || true
kubectl delete clusterrole k3s-resource-reconciler 2>/dev/null || true
kubectl delete serviceaccount k3s-resource-reconciler-sa -n kube-system 2>/dev/null || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6b: Delete the duplicate conflicting HPA (subscore 8)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 6b: Removing duplicate HPA..."
kubectl delete hpa bleater-gateway-scaling-v2 -n "$NS" 2>/dev/null && \
    echo "  ✓ bleater-gateway-scaling-v2 deleted" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Fix metrics-server deployment args
# Remove ExternalIP arg, remove stale metric-resolution, restore --kubelet-insecure-tls
# Use RBAC-scoped kubectl (kube-system-metrics-fixer Role grants patch on metrics-server)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 7: Fixing metrics-server deployment..."

kubectl get deployment metrics-server -n kube-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
args = c.get('args', [])
# Remove bad args
args = [a for a in args if 'ExternalIP' not in a and '--metric-resolution=600s' not in a]
# Ensure --kubelet-insecure-tls is present
if '--kubelet-insecure-tls' not in args:
    args.append('--kubelet-insecure-tls')
# Ensure reasonable metric resolution
args = [a for a in args if not a.startswith('--metric-resolution')]
args.append('--metric-resolution=15s')
c['args'] = args
patch = {'spec': {'template': {'spec': {'containers': [{'name': c['name'], 'args': c['args']}]}}}}
print(json.dumps(patch))
" | kubectl patch deployment metrics-server -n kube-system \
    --type=strategic --patch-file=/dev/stdin

echo "  ✓ metrics-server deployment fixed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Fix metrics-server Service selector
# The selector was changed from k8s-app: metrics-server to k8s-app: metrics-aggregator
# Use RBAC-scoped kubectl (kube-system-metrics-fixer Role grants patch on metrics-server)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 8: Fixing metrics-server Service selector..."

kubectl patch service metrics-server -n kube-system --type=json \
  -p='[{"op":"replace","path":"/spec/selector/k8s-app","value":"metrics-server"}]' \
  2>/dev/null && echo "  ✓ Service selector fixed" || true

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Fix deployment resource requests (subscore 7)
# Set proper CPU request and limit
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 9: Fixing deployment resource requests..."

kubectl patch deployment bleater-api-gateway -n "$NS" --type=strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "api-gateway",
          "resources": {
            "requests": {
              "cpu": "100m",
              "memory": "128Mi"
            },
            "limits": {
              "cpu": "500m",
              "memory": "512Mi"
            }
          }
        }]
      }
    }
  }
}'

echo "  ✓ Deployment resources fixed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: Patch the HPA with correct production-stable configuration
# Fixes: target, stabilization windows, policies, selectPolicy, metrics, replicas
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 10: Patching HPA with production-stable configuration..."

# Replace the entire HPA spec to ensure clean state
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $HPA_NAME
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
      stabilizationWindowSeconds: 300
      selectPolicy: Min
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      selectPolicy: Min
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
EOF

echo "  ✓ HPA patched"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: Wait for metrics-server to become healthy
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 11: Waiting for metrics-server to become healthy..."
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s 2>/dev/null || true
sleep 30

# Verify metrics are flowing
echo "  Checking metrics API..."
for i in 1 2 3 4 5; do
    if kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | grep -q '"items"'; then
        echo "  ✓ Metrics API healthy"
        break
    fi
    echo "  Waiting for metrics... ($i/5)"
    sleep 15
done
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 12: Verify stability — wait 90s to ensure nothing reverts
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 12: Verifying stability (90s)..."
sleep 90

echo "  Final HPA state:"
kubectl get hpa "$HPA_NAME" -n "$NS"
echo ""
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 30 "behavior:"
echo ""

# Verify no duplicate HPAs
echo "  HPAs in bleater namespace:"
kubectl get hpa -n "$NS"
echo ""

# Verify no enforcers remain
echo "  Remaining CronJobs:"
for ns in "$OPS_NS" "$ENV_NS" "$DEFAULT_NS"; do
    echo "  --- $ns ---"
    kubectl get cronjobs -n "$ns" 2>/dev/null || echo "  (none)"
done
echo ""

# Verify no blocking LimitRange
echo "  LimitRanges in bleater:"
kubectl get limitrange -n "$NS" 2>/dev/null || echo "  (none)"
echo ""

# Verify APIService is correct
echo "  APIService v1beta1.metrics.k8s.io:"
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.spec.service}' 2>/dev/null
echo ""

# Verify static pod manifest is gone
echo "  Static pod manifests:"
sudo ls /var/lib/rancher/k3s/agent/pod-manifests/ 2>/dev/null || echo "  (directory empty or gone)"
echo ""

echo "=== Done ==="
