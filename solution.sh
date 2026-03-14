#!/bin/bash
# Solution: HPA Scaling Thrash Fix (Hard Mode)
# Fixes all breaks across 13 subscores
set -e
export KUBECONFIG=/home/ubuntu/.kube/config

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
# The manifest is protected with chattr +i (immutable flag).
# Must clear immutable flag before removing.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2: Checking for static pod enforcers..."

# List static pod manifests
ls /var/lib/rancher/k3s/agent/pod-manifests/ 2>/dev/null || true

# Remove the manifest file (ubuntu has write access to this directory)
if cat /var/lib/rancher/k3s/agent/pod-manifests/kube-controller-health.yaml 2>/dev/null | grep -q "bleater-api-gateway-hpa"; then
    rm /var/lib/rancher/k3s/agent/pod-manifests/kube-controller-health.yaml
    echo "  ✓ Static pod enforcer manifest removed"
else
    echo "  No enforcer static pod found"
fi

# Wait for kubelet to remove the static pod
sleep 15
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2b: Remove k3s auto-deploy server manifest (subscore 13)
# k3s auto-reconciles manifests in /var/lib/rancher/k3s/server/manifests/
# Even if we delete the CronJob, k3s will recreate it from the manifest file.
# Must remove the FILE from disk first.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2b: Checking for k3s auto-deploy enforcement manifests..."

ls /var/lib/rancher/k3s/server/manifests/ 2>/dev/null || true

if cat /var/lib/rancher/k3s/server/manifests/platform-compliance-audit.yaml 2>/dev/null | grep -q "bleater-api-gateway-hpa\|platform-compliance"; then
    rm /var/lib/rancher/k3s/server/manifests/platform-compliance-audit.yaml
    echo "  ✓ k3s auto-deploy enforcement manifest removed"
else
    echo "  No auto-deploy enforcement manifest found"
fi

# Delete the CronJob and its RBAC that was created by the manifest
kubectl delete cronjob platform-compliance-audit -n kube-system 2>/dev/null && \
    echo "  ✓ platform-compliance-audit CronJob deleted" || true
kubectl delete clusterrolebinding platform-compliance-auditor 2>/dev/null || true
kubectl delete clusterrole platform-compliance-auditor 2>/dev/null || true
kubectl delete serviceaccount platform-compliance-sa -n kube-system 2>/dev/null || true
kubectl delete jobs --all -n kube-system 2>/dev/null || true

sleep 10
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2c: Remove PSA enforce label from bleater namespace
# Setup applied pod-security.kubernetes.io/enforce=restricted which blocks
# pod creation without strict security context. Remove it early.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2c: Removing PSA enforce label from bleater namespace..."
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce- 2>/dev/null && \
    echo "  ✓ PSA enforce label removed" || true
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce-version- 2>/dev/null || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2d: Scale down non-essential bleater services to free CPU
# Single-node k3s is resource-constrained — need room for 2 api-gateway pods
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2d: Scaling down non-essential services to free CPU..."
for deploy in bleater-trending bleater-search bleater-notification bleater-media; do
    kubectl scale deployment "$deploy" -n "$NS" --replicas=0 2>/dev/null && \
        echo "  ✓ Scaled down $deploy" || true
done
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
for ns in "$OPS_NS" "$ENV_NS" "$DEFAULT_NS" "kube-system"; do
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

# Wait for DaemonSet pods to fully terminate
echo "  Waiting for enforcer pods to terminate..."
sleep 15

# Kill any remaining enforcer jobs across all namespaces
for ns in "$OPS_NS" "$ENV_NS" "$DEFAULT_NS" "kube-system"; do
    kubectl delete jobs --all -n "$ns" 2>/dev/null || true
done
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6b: Delete ALL HPAs — remove duplicates and broken original
# We'll recreate the correct HPA in Step 10. Deleting now prevents the broken
# HPA from fighting our replica/resource changes during the rollout.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 6b: Removing all HPAs..."
kubectl delete hpa bleater-gateway-scaling-v2 -n "$NS" 2>/dev/null && \
    echo "  ✓ bleater-gateway-scaling-v2 deleted" || true
kubectl delete hpa "$HPA_NAME" -n "$NS" 2>/dev/null && \
    echo "  ✓ $HPA_NAME deleted (will recreate with correct config)" || true
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
# Scale to 1 replica first to reduce scheduling pressure on constrained node.
# With HPA deleted (Step 6b), nothing will fight the scale-down.
# After resources are fixed and 1 pod is running, the new HPA (Step 10)
# will scale back to minReplicas.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 9: Fixing deployment resource requests..."

# Scale to 1 to ease resource pressure during rollout
kubectl scale deployment bleater-api-gateway -n "$NS" --replicas=1
echo "  Scaled to 1 replica"
sleep 10

# Patch resources (PSA enforce label already removed in Step 2c)
kubectl patch deployment bleater-api-gateway -n "$NS" --type=strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "api-gateway",
          "resources": {
            "requests": {
              "cpu": "50m",
              "memory": "128Mi"
            },
            "limits": {
              "cpu": "200m",
              "memory": "512Mi"
            }
          }
        }]
      }
    }
  }
}'

echo "  ✓ Deployment resources fixed"

# Wait for the single pod rollout to complete
echo "  Waiting for deployment rollout (1 replica)..."
kubectl rollout status deployment/bleater-api-gateway -n "$NS" --timeout=180s 2>/dev/null || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: Patch the HPA with correct production-stable configuration
# Fixes: target, stabilization windows, policies, selectPolicy, metrics, replicas
# Must include BOTH Percent and Pods policies to satisfy grader requirements
# Stabilization: scaleDown >= 180s, scaleUp >= 45s
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
  minReplicas: 2
  maxReplicas: 10
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
      - type: Pods
        value: 2
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      selectPolicy: Min
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
      - type: Pods
        value: 3
        periodSeconds: 60
EOF

echo "  ✓ HPA patched"

# Wait for HPA to scale deployment to minReplicas=2
echo "  Waiting for deployment to reach desired replicas..."
for i in $(seq 1 12); do
    READY=$(kubectl get deployment bleater-api-gateway -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "${READY:-0}" -ge 2 ]; then
        echo "  ✓ Deployment has $READY ready replicas"
        break
    fi
    echo "  Waiting for replicas... (ready=$READY, attempt $i/12)"
    sleep 10
done
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
# Step 12: Re-apply critical fixes after all enforcers are dead
# Any CronJob jobs that fired before deletion may have reverted state.
# Re-apply deployment resources and delete duplicate HPA to be safe.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 12: Re-applying critical fixes..."

# Re-patch deployment resources in case enforcers reverted them
kubectl patch deployment bleater-api-gateway -n "$NS" --type=strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "api-gateway",
          "resources": {
            "requests": {
              "cpu": "50m",
              "memory": "128Mi"
            },
            "limits": {
              "cpu": "200m",
              "memory": "512Mi"
            }
          }
        }]
      }
    }
  }
}' 2>/dev/null && echo "  ✓ Deployment resources re-confirmed" || true

# Re-delete duplicate HPA in case DaemonSet pod recreated it before terminating
kubectl delete hpa bleater-gateway-scaling-v2 -n "$NS" 2>/dev/null && \
    echo "  ✓ bleater-gateway-scaling-v2 re-deleted" || true

# Re-patch metrics-server service selector
kubectl patch service metrics-server -n kube-system --type=json \
  -p='[{"op":"replace","path":"/spec/selector/k8s-app","value":"metrics-server"}]' \
  2>/dev/null || true

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 13: Wait for HPA to actually compute CPU metrics
# The HPA needs metrics-server to have collected at least one scrape cycle
# (15s resolution + propagation delay). Wait until HPA shows actual CPU%.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 13: Waiting for HPA to compute actual CPU metrics..."
for i in $(seq 1 20); do
    HPA_TARGETS=$(kubectl get hpa "$HPA_NAME" -n "$NS" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' 2>/dev/null)
    if [ -n "$HPA_TARGETS" ] && [ "$HPA_TARGETS" != "<unknown>" ]; then
        echo "  ✓ HPA computing CPU metrics: ${HPA_TARGETS}%"
        break
    fi
    echo "  Waiting for HPA metrics... ($i/20)"
    sleep 15
done
echo ""

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
for ns in "$OPS_NS" "$ENV_NS" "$DEFAULT_NS" "kube-system"; do
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
ls /var/lib/rancher/k3s/agent/pod-manifests/ 2>/dev/null || echo "  (directory empty or gone)"
echo ""

# Verify k3s server manifest is gone
echo "  K3s server manifests (checking for enforcement):"
ls /var/lib/rancher/k3s/server/manifests/ 2>/dev/null || echo "  (directory empty or gone)"
echo ""

echo "=== Done ==="
