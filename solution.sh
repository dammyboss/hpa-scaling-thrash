#!/bin/bash
# Solution: HPA Scaling Thrash Fix (CronJob enforcement variant)
set -e

NS="bleater"
OPS_NS="kube-ops"
HPA_NAME="bleater-api-gateway-hpa"

echo "=== HPA Scaling Thrash Fix ==="
echo ""

# Step 1: Inspect current HPA state
echo "Step 1: Inspecting current HPA..."
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml
echo ""

# Step 2: Check all namespaces accessible
echo "Step 2: Auditing namespaces..."
for ns in bleater bleater-env default kube-ops kube-system; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "  ✓ $ns accessible"
    fi
done
echo ""

# Step 3: Check CronJobs in kube-ops — real enforcers live here
echo "Step 3: Auditing CronJobs in kube-ops..."
kubectl get cronjobs -n "$OPS_NS" -o wide
echo ""

# Step 4: Inspect each CronJob command to identify real enforcers vs decoys
echo "Step 4: Inspecting CronJob commands..."
for cj in $(kubectl get cronjobs -n "$OPS_NS" -o jsonpath='{.items[*].metadata.name}'); do
    echo "--- $cj ---"
    kubectl get cronjob "$cj" -n "$OPS_NS" \
        -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}'
    echo ""
done
echo ""

# Step 5: Delete real enforcer CronJobs
# containerd-log-rotate → resets scaleDown.stabilizationWindowSeconds
# cni-bridge-monitor    → resets scaleUp.stabilizationWindowSeconds
# oom-score-adjuster    → resets scaleDown.policies
# node-pressure-monitor → resets scaleUp.policies
echo "Step 5: Deleting enforcer CronJobs..."
kubectl delete cronjob containerd-log-rotate -n "$OPS_NS" && echo "  ✓ containerd-log-rotate deleted"
kubectl delete cronjob cni-bridge-monitor    -n "$OPS_NS" && echo "  ✓ cni-bridge-monitor deleted"
kubectl delete cronjob oom-score-adjuster    -n "$OPS_NS" && echo "  ✓ oom-score-adjuster deleted"
kubectl delete cronjob node-pressure-monitor -n "$OPS_NS" && echo "  ✓ node-pressure-monitor deleted"

# Also delete any running jobs from those CronJobs
kubectl delete jobs --all -n "$OPS_NS" 2>/dev/null || true
echo ""

# Step 6: Fix metrics-server
echo "Step 6: Fixing metrics-server..."
ARGS=$(kubectl get deployment metrics-server -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].args}')
echo "  Current args: $ARGS"

kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args/-"}]' \
  2>/dev/null || true

# Remove ExternalIP arg specifically
kubectl get deployment metrics-server -n kube-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
c['args'] = [a for a in c.get('args', []) if 'ExternalIP' not in a]
patch = {'spec': {'template': {'spec': {'containers': [{'name': c['name'], 'args': c['args']}]}}}}
print(json.dumps(patch))
" | kubectl patch deployment metrics-server -n kube-system \
    --type=strategic --patch-file=/dev/stdin
echo "  ✓ metrics-server fixed"
echo ""

# Step 7: Patch HPA with correct stable values
echo "Step 7: Patching HPA with production-stable configuration..."
kubectl patch hpa "$HPA_NAME" -n "$NS" --type=merge -p '{
  "spec": {
    "behavior": {
      "scaleDown": {
        "stabilizationWindowSeconds": 300,
        "policies": [{"type": "Percent", "value": 10, "periodSeconds": 60}]
      },
      "scaleUp": {
        "stabilizationWindowSeconds": 60,
        "policies": [{"type": "Percent", "value": 50, "periodSeconds": 60}],
        "selectPolicy": "Max"
      }
    }
  }
}'
echo "  ✓ HPA patched"
echo ""

# Step 8: Verify stability — wait 90s to ensure nothing reverts
echo "Step 8: Verifying stability (90s)..."
sleep 90
echo ""
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 25 "behavior:"
echo ""
echo "=== Done ==="
