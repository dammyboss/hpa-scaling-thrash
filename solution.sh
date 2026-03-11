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
# Step 2: Delete the MutatingWebhookConfiguration FIRST
# This webhook silently rewrites HPA and Deployment patches back to broken
# values. Must be removed before any patches will stick.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2: Checking for mutating admission webhooks..."
sudo kubectl get mutatingwebhookconfigurations 2>/dev/null || true

echo "  Removing platform-scaling-policy webhook..."
sudo kubectl delete mutatingwebhookconfiguration platform-scaling-policy 2>/dev/null && \
    echo "  ✓ platform-scaling-policy webhook deleted" || true

# Also remove the webhook server Deployment, Service, Secret, and ConfigMap
echo "  Removing webhook server components from kube-system..."
sudo kubectl delete deployment scaling-policy-validator -n kube-system 2>/dev/null && \
    echo "  ✓ scaling-policy-validator deployment deleted" || true
sudo kubectl delete service scaling-policy-validator -n kube-system 2>/dev/null && \
    echo "  ✓ scaling-policy-validator service deleted" || true
sudo kubectl delete secret scaling-policy-validator-tls -n kube-system 2>/dev/null && \
    echo "  ✓ scaling-policy-validator-tls secret deleted" || true
sudo kubectl delete configmap scaling-policy-validator-script -n kube-system 2>/dev/null && \
    echo "  ✓ scaling-policy-validator-script configmap deleted" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Delete the CronJob Resurrection Controller
# This Deployment in kube-ops re-creates deleted CronJobs every 2 minutes.
# Must be removed before deleting CronJobs or they'll come back.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 3: Checking for resurrection controllers..."
kubectl get deployments -n "$OPS_NS" 2>/dev/null || true

echo "  Removing platform-controller-manager..."
kubectl delete deployment platform-controller-manager -n "$OPS_NS" 2>/dev/null && \
    echo "  ✓ platform-controller-manager deployment deleted" || true
kubectl delete configmap platform-controller-manifests -n "$OPS_NS" 2>/dev/null && \
    echo "  ✓ platform-controller-manifests configmap deleted" || true
kubectl delete configmap platform-controller-manager-script -n "$OPS_NS" 2>/dev/null && \
    echo "  ✓ platform-controller-manager-script configmap deleted" || true

# Kill any running pods from the controller
kubectl delete pods -l app=platform-controller-manager -n "$OPS_NS" --force 2>/dev/null || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Discover and delete ALL enforcer CronJobs across all namespaces
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 4: Discovering CronJobs across all namespaces..."
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
# Step 5: Delete the duplicate conflicting HPA (subscore 8)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 5: Removing duplicate HPA..."
kubectl delete hpa bleater-gateway-scaling-v2 -n "$NS" 2>/dev/null && \
    echo "  ✓ bleater-gateway-scaling-v2 deleted" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Fix metrics-server deployment args
# Remove ExternalIP arg, remove stale metric-resolution, restore --kubelet-insecure-tls
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 6: Fixing metrics-server deployment..."

sudo kubectl get deployment metrics-server -n kube-system -o json | \
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
" | sudo kubectl patch deployment metrics-server -n kube-system \
    --type=strategic --patch-file=/dev/stdin

echo "  ✓ metrics-server deployment fixed"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Fix metrics-server Service selector (subscore 12)
# The selector was changed from k8s-app: metrics-server to k8s-app: metrics-aggregator
# so the Service can't find the metrics-server pods even though they're running.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 7: Fixing metrics-server Service selector..."

sudo kubectl patch service metrics-server -n kube-system --type=json \
  -p='[{"op":"replace","path":"/spec/selector/k8s-app","value":"metrics-server"}]' \
  2>/dev/null && echo "  ✓ Service selector fixed" || true

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Fix deployment resource requests (subscore 7)
# Set proper CPU request and limit
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 8: Fixing deployment resource requests..."

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
# Step 9: Patch the HPA with correct production-stable configuration
# Fixes: target, stabilization windows, policies, selectPolicy, metrics, replicas
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 9: Patching HPA with production-stable configuration..."

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
# Step 10: Wait for metrics-server to become healthy
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 10: Waiting for metrics-server to become healthy..."
sudo kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s 2>/dev/null || true
sleep 30

# Verify metrics are flowing
echo "  Checking metrics API..."
for i in 1 2 3 4 5; do
    if sudo kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | grep -q '"items"'; then
        echo "  ✓ Metrics API healthy"
        break
    fi
    echo "  Waiting for metrics... ($i/5)"
    sleep 15
done
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: Verify stability — wait 90s to ensure nothing reverts
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 11: Verifying stability (90s)..."
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

# Verify webhook is gone
echo "  Mutating webhooks:"
sudo kubectl get mutatingwebhookconfigurations 2>/dev/null || echo "  (none)"
echo ""

# Verify metrics-server Service has endpoints
echo "  Metrics-server Service endpoints:"
sudo kubectl get endpoints metrics-server -n kube-system 2>/dev/null || echo "  (none)"
echo ""

echo "=== Done ==="
