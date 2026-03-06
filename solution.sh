#!/bin/bash
# Solution: HPA Scaling Thrash Fix
set -e

NS="bleater"
HPA_NAME="bleater-api-gateway-hpa"

echo "=== HPA Scaling Thrash Fix ==="
echo ""

# Step 1: Inspect current HPA
echo "Step 1: Inspecting current HPA..."
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml
echo ""

# Step 2: Find background enforcement scripts resetting the HPA
echo "Step 2: Finding background enforcement processes..."
ps aux | grep -E "\.sh" | grep -v grep | head -20
echo ""

# Step 3: Check cron jobs
echo "Step 3: Checking cron jobs..."
ls /etc/cron.d/
echo ""
cat /etc/cron.d/do_not_touch 2>/dev/null || echo "(not found)"
echo ""

# Step 4: Read and identify each script
echo "Step 4: Identifying enforcement scripts..."
for script in \
    /usr/local/sbin/containerd-log-rotate.sh \
    /usr/local/sbin/cni-bridge-monitor.sh \
    /usr/lib/k3s/oom-score-adjuster.sh \
    /opt/k8s/node-pressure-monitor.sh \
    /usr/local/bin/cluster-policy-sync.sh \
    /usr/local/bin/node-metrics-collector.sh; do
    if [ -f "$script" ]; then
        echo "--- $script ---"
        cat "$script"
        echo ""
    fi
done

# Step 5: Kill all real enforcement scripts using scoped sudo
echo "Step 5: Stopping enforcement scripts..."
sudo pkill -f containerd-log-rotate.sh  && echo "  ✓ Killed containerd-log-rotate.sh" || true
sudo pkill -f cni-bridge-monitor.sh     && echo "  ✓ Killed cni-bridge-monitor.sh" || true
sudo pkill -f oom-score-adjuster.sh     && echo "  ✓ Killed oom-score-adjuster.sh" || true
sudo pkill -f node-pressure-monitor.sh  && echo "  ✓ Killed node-pressure-monitor.sh" || true
sudo pkill -f cluster-policy-sync.sh   2>/dev/null || true
sudo pkill -f node-metrics-collector.sh 2>/dev/null || true

# Step 6: Remove the do_not_touch cron backup
# (cron.d files are world-readable, owned by root — agent can verify but not delete without sudo)
# NOTE: agent cannot rm /etc/cron.d/do_not_touch without full sudo
# But the cron daemon is NOT installed, so cron.d is inert (safe to leave)
echo "Step 6: Checking if cron is running..."
if ! which cron >/dev/null 2>&1 && ! which crond >/dev/null 2>&1; then
    echo "  ✓ cron daemon not installed — cron.d files are inert"
else
    echo "  ⚠ cron is running — do_not_touch will continue to fire"
fi
echo ""

# Step 7: Fix metrics-server
echo "Step 7: Fixing metrics-server..."
sudo kubectl get deployment metrics-server -n kube-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
c['args'] = [a for a in c.get('args', []) if 'ExternalIP' not in a]
patch = {'spec': {'template': {'spec': {'containers': [{'name': c['name'], 'args': c['args']}]}}}}
sys.stdout.write(json.dumps(patch))
" | sudo kubectl patch deployment metrics-server -n kube-system --type=strategic -p "$(cat /dev/stdin)"
echo "  ✓ metrics-server fixed"
echo ""

# Step 8: Patch HPA with stable values — now that enforcers are dead, this will stick
echo "Step 8: Patching HPA..."
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

# Step 9: Verify HPA held
echo "Step 9: Verifying stability (60s)..."
sleep 60
kubectl get hpa "$HPA_NAME" -n "$NS" -o yaml | grep -A 20 "behavior:"
echo ""
echo "=== Done ==="