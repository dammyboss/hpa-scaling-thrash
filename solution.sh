#!/bin/bash
# NOTE: No set -e — solution runs as ubuntu but must kill root-owned processes

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

echo "Step 4: Auditing background processes across all locations..."
ps aux | grep -E "\.sh" | grep -v grep || true
echo ""
echo "Scripts in /usr/local/bin/:"
ls /usr/local/bin/*.sh 2>/dev/null || true
echo "Scripts in /usr/local/sbin/:"
ls /usr/local/sbin/*.sh 2>/dev/null || true
echo "Scripts in /usr/lib/k3s/:"
ls /usr/lib/k3s/*.sh 2>/dev/null || true
echo "Scripts in /opt/k8s/:"
ls /opt/k8s/*.sh 2>/dev/null || true
echo ""

echo "Step 5: Stopping cluster-policy-sync background loop..."
if [ -f /var/run/cluster-policy-sync.pid ]; then
    sudo kill "$(cat /var/run/cluster-policy-sync.pid)" 2>/dev/null || true
    sudo rm -f /var/run/cluster-policy-sync.pid 2>/dev/null || true
fi
sudo pkill -f cluster-policy-sync.sh 2>/dev/null || true
echo "✓ cluster-policy-sync stopped"
echo ""

echo "Step 6: Stopping node-metrics-collector background loop..."
if [ -f /var/run/node-metrics-collector.pid ]; then
    sudo kill "$(cat /var/run/node-metrics-collector.pid)" 2>/dev/null || true
    sudo rm -f /var/run/node-metrics-collector.pid 2>/dev/null || true
fi
sudo pkill -f node-metrics-collector.sh 2>/dev/null || true
echo "✓ node-metrics-collector stopped"
echo ""

echo "Step 7: Removing do_not_touch cron (backup HPA resetter)..."
sudo rm -f /etc/cron.d/do_not_touch 2>/dev/null || true
echo "✓ do_not_touch cron removed"
echo ""

echo "Step 8: Stopping containerd-log-rotate (scaleDown stabilization enforcer)..."
if [ -f /var/run/containerd-log-rotate.pid ]; then
    sudo kill "$(cat /var/run/containerd-log-rotate.pid)" 2>/dev/null || true
    sudo rm -f /var/run/containerd-log-rotate.pid 2>/dev/null || true
fi
sudo pkill -f containerd-log-rotate.sh 2>/dev/null || true
echo "✓ containerd-log-rotate stopped"
echo ""

echo "Step 9: Stopping cni-bridge-monitor (scaleUp stabilization enforcer)..."
if [ -f /var/run/cni-bridge-monitor.pid ]; then
    sudo kill "$(cat /var/run/cni-bridge-monitor.pid)" 2>/dev/null || true
    sudo rm -f /var/run/cni-bridge-monitor.pid 2>/dev/null || true
fi
sudo pkill -f cni-bridge-monitor.sh 2>/dev/null || true
echo "✓ cni-bridge-monitor stopped"
echo ""

echo "Step 10: Stopping oom-score-adjuster (scaleDown policy enforcer)..."
if [ -f /var/run/oom-score-adjuster.pid ]; then
    sudo kill "$(cat /var/run/oom-score-adjuster.pid)" 2>/dev/null || true
    sudo rm -f /var/run/oom-score-adjuster.pid 2>/dev/null || true
fi
sudo pkill -f oom-score-adjuster.sh 2>/dev/null || true
echo "✓ oom-score-adjuster stopped"
echo ""

echo "Step 11: Stopping node-pressure-monitor (scaleUp policy enforcer)..."
if [ -f /var/run/node-pressure-monitor.pid ]; then
    sudo kill "$(cat /var/run/node-pressure-monitor.pid)" 2>/dev/null || true
    sudo rm -f /var/run/node-pressure-monitor.pid 2>/dev/null || true
fi
sudo pkill -f node-pressure-monitor.sh 2>/dev/null || true
echo "✓ node-pressure-monitor stopped"
echo ""

echo "Step 12: Fixing metrics-server (removing bad kubelet address type)..."
kubectl get deployment metrics-server -n kube-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
c['args'] = [a for a in c.get('args', []) if 'ExternalIP' not in a]
patch = {'spec': {'template': {'spec': {'containers': [{'name': c['name'], 'args': c['args']}]}}}}
sys.stdout.write(json.dumps(patch))
" | kubectl patch deployment metrics-server -n kube-system --type=strategic -p "$(cat /dev/stdin)"
kubectl rollout status deployment/metrics-server -n kube-system --timeout=90s 2>/dev/null || true
echo "✓ metrics-server fixed"
echo ""

echo "Step 13: Updating hpa-policy-config with stable values..."
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

echo "Step 14: Patching HPA directly with stable behavior..."
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

echo "Step 15: Verifying final HPA configuration..."
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 20 "behavior:" || true

echo ""
echo "=== Solution Complete ==="
echo ""
echo "Summary:"
echo "✅ Stopped cluster-policy-sync (ConfigMap reset loop — decoy)"
echo "✅ Stopped node-metrics-collector (ConfigMap audit logger — decoy)"
echo "✅ Removed do_not_touch cron (full HPA backup resetter)"
echo "✅ Stopped containerd-log-rotate (scaleDown stabilization enforcer)"
echo "✅ Stopped cni-bridge-monitor (scaleUp stabilization enforcer)"
echo "✅ Stopped oom-score-adjuster (scaleDown policy enforcer)"
echo "✅ Stopped node-pressure-monitor (scaleUp policy enforcer)"
echo "✅ Fixed metrics-server (removed ExternalIP-only constraint)"
echo "✅ Updated hpa-policy-config with stable values"
echo "✅ Patched HPA directly with correct behavior"
echo ""
