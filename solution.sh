#!/bin/bash
set -e

echo "=== HPA Scaling Thrash Fix Solution ==="
echo ""

NS="bleater"
HPA_NAME="bleater-api-gateway-hpa"

echo "Step 1: Inspecting current HPA configuration..."
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 20 "behavior:" || true
echo ""

echo "Step 2: Checking ConfigMaps..."
kubectl get configmaps -n "$NS" 2>/dev/null || true
echo ""
kubectl get configmap hpa-policy-config -n "$NS" -o yaml 2>/dev/null || true
echo ""

echo "Step 3: Auditing all cron jobs..."
ls /etc/cron.d/ 2>/dev/null || true
echo ""
for f in /etc/cron.d/*; do
    echo "==> $f"
    cat "$f" 2>/dev/null || true
    echo ""
done

echo "Step 4: Auditing background processes..."
ps aux | grep -E "node-metrics|cluster-policy|collector|sync" | grep -v grep || true
echo ""

echo "Step 5: Stopping cluster-policy-sync background loop..."
if [ -f /var/run/cluster-policy-sync.pid ]; then
    kill "$(cat /var/run/cluster-policy-sync.pid)" 2>/dev/null || true
    rm -f /var/run/cluster-policy-sync.pid
fi
pkill -f cluster-policy-sync.sh 2>/dev/null || true
echo "✓ cluster-policy-sync loop stopped"
echo ""

echo "Step 6: Removing do_not_touch cron (backup ConfigMap resetter)..."
rm -f /etc/cron.d/do_not_touch
echo "✓ do_not_touch cron removed"
echo ""

echo "Step 7: Stopping node-metrics-collector background loop..."
if [ -f /var/run/node-metrics-collector.pid ]; then
    kill "$(cat /var/run/node-metrics-collector.pid)" 2>/dev/null || true
    rm -f /var/run/node-metrics-collector.pid
fi
pkill -f node-metrics-collector.sh 2>/dev/null || true
echo "✓ node-metrics-collector stopped"
echo ""

echo "Step 8: Updating hpa-policy-config with stable values..."
kubectl patch configmap hpa-policy-config -n "$NS" --type=merge -p '{
  "data": {
    "scaledown_window": "300",
    "scaleup_window": "60",
    "scaledown_percent": "10",
    "scaledown_period": "60",
    "scaleup_percent": "50",
    "scaleup_period": "60"
  }
}'
echo "✓ ConfigMap updated"
echo ""

echo "Step 9: Patching HPA directly with stable behavior..."
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
echo "✓ HPA patched"
echo ""

echo "Step 10: Verifying final HPA configuration..."
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 20 "behavior:" || true

echo ""
echo "=== Solution Complete ==="
echo ""
echo "Summary:"
echo "✅ Identified node-metrics-collector enforcing HPA from hpa-policy-config ConfigMap"
echo "✅ Identified cluster-policy-sync loop resetting ConfigMap every 10s"
echo "✅ Identified do_not_touch cron as backup ConfigMap resetter (every ~20s)"
echo "✅ Stopped all three enforcement mechanisms"
echo "✅ Updated hpa-policy-config with stable values (scaleDown=300s, scaleUp=60s)"
echo "✅ Patched HPA directly with correct behavior"
echo ""
