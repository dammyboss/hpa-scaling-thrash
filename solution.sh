#!/bin/bash
# Solution: HPA Scaling Thrash Fix
# All operations via kubectl only — no sudo required.

set -e

NS="bleater"
HPA_NAME="bleater-api-gateway-hpa"

echo "=== HPA Scaling Thrash Fix ==="
echo ""

# ============================================================
# Step 1: Understand what's wrong with the HPA
# ============================================================
echo "Step 1: Inspecting current HPA configuration..."
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml
echo ""

# ============================================================
# Step 2: Find what's resetting the HPA back to bad values.
# Agents need to check ALL namespaces for CronJobs, not just bleater.
# The real enforcers live in kube-ops and kube-system.
# ============================================================
echo "Step 2: Auditing CronJobs across all accessible namespaces..."
echo ""
echo "--- bleater namespace ---"
kubectl get cronjobs -n bleater 2>/dev/null || echo "  (none)"
echo ""
echo "--- kube-ops namespace ---"
kubectl get cronjobs -n kube-ops 2>/dev/null || echo "  (none)"
echo ""
echo "--- kube-system namespace ---"
kubectl get cronjobs -n kube-system 2>/dev/null || echo "  (none)"
echo ""

echo "Step 3: Inspecting kube-ops CronJobs to identify real enforcers vs decoys..."
echo ""
for cj in hpa-stabilization-sync metrics-aggregation-daemon cluster-policy-reconciler node-resource-optimizer hpa-policy-enforcer hpa-config-manager scaling-event-monitor; do
    echo "--- kube-ops/$cj ---"
    kubectl get cronjob "$cj" -n kube-ops -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}' 2>/dev/null | tr ',' '\n' || echo "  (not found)"
    echo ""
done

echo "Step 4: Inspecting kube-system CronJob..."
kubectl get cronjob platform-config-manager -n kube-system -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}' 2>/dev/null | tr ',' '\n' || echo "  (not found)"
echo ""

# ============================================================
# Step 5: Delete all real enforcement CronJobs.
# Deleting the CronJob also stops any currently-running Jobs.
# The decoys can be left or deleted — they don't affect the HPA.
# The kube-system backup enforcer MUST also be deleted.
# ============================================================
echo "Step 5: Deleting real enforcement CronJobs from kube-ops..."
kubectl delete cronjob hpa-stabilization-sync      -n kube-ops 2>/dev/null && echo "  ✓ Deleted hpa-stabilization-sync" || true
kubectl delete cronjob metrics-aggregation-daemon  -n kube-ops 2>/dev/null && echo "  ✓ Deleted metrics-aggregation-daemon" || true
kubectl delete cronjob cluster-policy-reconciler   -n kube-ops 2>/dev/null && echo "  ✓ Deleted cluster-policy-reconciler" || true
kubectl delete cronjob node-resource-optimizer     -n kube-ops 2>/dev/null && echo "  ✓ Deleted node-resource-optimizer" || true
echo ""

echo "Step 6: Deleting backup enforcement CronJob from kube-system..."
kubectl delete cronjob platform-config-manager -n kube-system 2>/dev/null && echo "  ✓ Deleted platform-config-manager" || true
echo ""

# Also delete any still-running Jobs spawned by the CronJobs
echo "Step 7: Cleaning up any running enforcement Jobs..."
kubectl delete jobs --all -n kube-ops   2>/dev/null || true
kubectl delete jobs --all -n kube-system --field-selector status.active=1 2>/dev/null || true
echo "  ✓ Running jobs cleaned up"
echo ""

# ============================================================
# Step 8: Fix metrics-server — remove the bad address type arg
# ============================================================
echo "Step 8: Fixing metrics-server (removing ExternalIP-only constraint)..."
kubectl get deployment metrics-server -n kube-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
c['args'] = [a for a in c.get('args', []) if 'ExternalIP' not in a]
patch = {'spec': {'template': {'spec': {'containers': [{'name': c['name'], 'args': c['args']}]}}}}
sys.stdout.write(json.dumps(patch))
" | kubectl patch deployment metrics-server -n kube-system --type=strategic -p "$(cat /dev/stdin)"
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
echo "  ✓ metrics-server fixed"
echo ""

# ============================================================
# Step 9: Patch HPA with correct stable behavior.
# Now that all enforcers are gone, this will stick.
# ============================================================
echo "Step 9: Patching HPA with stable production behavior..."
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

# ============================================================
# Step 10: Verify the fix held (wait 90s, check again)
# ============================================================
echo "Step 10: Verifying HPA config is stable (waiting 90 seconds)..."
sleep 90
echo ""
echo "Final HPA state:"
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 25 "behavior:"
echo ""

echo "=== Solution Complete ==="
echo ""
echo "Summary:"
echo "  ✅ Deleted kube-ops/hpa-stabilization-sync      (was resetting scaleDown window to 10s)"
echo "  ✅ Deleted kube-ops/metrics-aggregation-daemon  (was resetting scaleUp window to 0s)"
echo "  ✅ Deleted kube-ops/cluster-policy-reconciler   (was resetting scaleDown policy to 60%/10s)"
echo "  ✅ Deleted kube-ops/node-resource-optimizer     (was resetting scaleUp policy to 150%/10s)"
echo "  ✅ Deleted kube-system/platform-config-manager  (backup enforcer for all HPA fields)"
echo "  ✅ Fixed metrics-server (removed --kubelet-preferred-address-types=ExternalIP)"
echo "  ✅ HPA patched: scaleDown 300s/10%, scaleUp 60s/50%"