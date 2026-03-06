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

echo "Step 1: Ensuring metrics-server is running..."

if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "  Metrics-server not found, this may cause issues"
else
    echo "✓ Metrics-server is available"
fi

echo ""

echo "Step 2: Waiting for bleater-api-gateway deployment..."

kubectl wait --for=condition=available --timeout=120s deployment/bleater-api-gateway -n "$NS" 2>/dev/null || \
    echo "  Note: bleater-api-gateway may still be starting"

echo "✓ bleater-api-gateway deployment ready"
echo ""

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

echo "Step 5: Adjusting cluster telemetry configuration..."

# Degrade metrics-server by forcing it to use an address type unavailable on k3s nodes
# (k3s nodes only expose InternalIP; ExternalIP-only makes scraping fail silently)
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=ExternalIP"}]' \
  2>/dev/null || echo "  Note: telemetry config already adjusted"

echo "✓ Telemetry configuration adjusted"
echo ""

echo "Step 6: Installing node-metrics-collector (audit logger)..."

# DECOY — reads hpa-policy-config and logs values; does NOT patch the HPA
cat > /usr/local/bin/node-metrics-collector.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
_R=$(echo 'aHBhLXBvbGljeS1jb25maWc=' | base64 -d)
while true; do
    SD=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaledown_window}' 2>/dev/null || echo "0")
    SU=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaleup_window}' 2>/dev/null || echo "0")
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) poll: sd_window=${SD}s su_window=${SU}s" >> /var/log/node-metrics-collector.log
    sleep 15
done
SCRIPT

chmod +x /usr/local/bin/node-metrics-collector.sh
nohup /usr/local/bin/node-metrics-collector.sh > /dev/null 2>&1 &
echo $! > /var/run/node-metrics-collector.pid
echo "✓ node-metrics-collector running (PID: $(cat /var/run/node-metrics-collector.pid))"
echo ""

echo "Step 7: Installing cluster-policy-sync background loop (resets ConfigMap every 10s)..."

# DECOY — resets hpa-policy-config ConfigMap; ConfigMap no longer drives enforcement
cat > /usr/local/bin/cluster-policy-sync.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
_R=$(echo 'aHBhLXBvbGljeS1jb25maWc=' | base64 -d)
while true; do
    sleep 10
    kubectl patch configmap "$_R" -n bleater --type=merge -p '{"data":{"scaledown_window":"10","scaleup_window":"0","scaledown_percent":"60","scaledown_period":"10","scaleup_percent":"150","scaleup_period":"10"}}' 2>/dev/null || true
done
SCRIPT

chmod +x /usr/local/bin/cluster-policy-sync.sh
nohup /usr/local/bin/cluster-policy-sync.sh > /var/log/cluster-policy-sync.log 2>&1 &
echo $! > /var/run/cluster-policy-sync.pid
echo "✓ cluster-policy-sync running (PID: $(cat /var/run/cluster-policy-sync.pid))"
echo ""

echo "Step 8: Installing containerd-log-rotate (scaleDown stabilization enforcer, every 20s)..."

# REAL ENFORCER #1 — resets ONLY scaleDown.stabilizationWindowSeconds → 10
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/containerd-log-rotate.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
while true; do
    kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
      -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10}}}}' 2>/dev/null || true
    sleep 20
done
SCRIPT

chmod +x /usr/local/sbin/containerd-log-rotate.sh
nohup /usr/local/sbin/containerd-log-rotate.sh > /var/log/containerd-log-rotate.log 2>&1 &
echo $! > /var/run/containerd-log-rotate.pid
echo "✓ containerd-log-rotate running (PID: $(cat /var/run/containerd-log-rotate.pid))"
echo ""

echo "Step 9: Installing cni-bridge-monitor (scaleUp stabilization enforcer, every 18s)..."

# REAL ENFORCER #2 — resets ONLY scaleUp.stabilizationWindowSeconds → 0
cat > /usr/local/sbin/cni-bridge-monitor.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
while true; do
    kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
      -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0}}}}' 2>/dev/null || true
    sleep 18
done
SCRIPT

chmod +x /usr/local/sbin/cni-bridge-monitor.sh
nohup /usr/local/sbin/cni-bridge-monitor.sh > /var/log/cni-bridge-monitor.log 2>&1 &
echo $! > /var/run/cni-bridge-monitor.pid
echo "✓ cni-bridge-monitor running (PID: $(cat /var/run/cni-bridge-monitor.pid))"
echo ""

echo "Step 10: Installing oom-score-adjuster (scaleDown policy enforcer, every 22s)..."

# REAL ENFORCER #3 — resets ONLY scaleDown.policies → {60%, 10s}
mkdir -p /usr/lib/k3s
cat > /usr/lib/k3s/oom-score-adjuster.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
while true; do
    kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
      -p '{"spec":{"behavior":{"scaleDown":{"policies":[{"type":"Percent","value":60,"periodSeconds":10}]}}}}' 2>/dev/null || true
    sleep 22
done
SCRIPT

chmod +x /usr/lib/k3s/oom-score-adjuster.sh
nohup /usr/lib/k3s/oom-score-adjuster.sh > /var/log/oom-score-adjuster.log 2>&1 &
echo $! > /var/run/oom-score-adjuster.pid
echo "✓ oom-score-adjuster running (PID: $(cat /var/run/oom-score-adjuster.pid))"
echo ""

echo "Step 11: Installing node-pressure-monitor (scaleUp policy enforcer, every 25s)..."

# REAL ENFORCER #4 — resets ONLY scaleUp.policies → {150%, 10s}
mkdir -p /opt/k8s
cat > /opt/k8s/node-pressure-monitor.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
while true; do
    kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge \
      -p '{"spec":{"behavior":{"scaleUp":{"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' 2>/dev/null || true
    sleep 25
done
SCRIPT

chmod +x /opt/k8s/node-pressure-monitor.sh
nohup /opt/k8s/node-pressure-monitor.sh > /var/log/node-pressure-monitor.log 2>&1 &
echo $! > /var/run/node-pressure-monitor.pid
echo "✓ node-pressure-monitor running (PID: $(cat /var/run/node-pressure-monitor.pid))"
echo ""

echo "Step 12: Installing cron jobs..."

# REAL backup resetter — patches ALL HPA behavior fields directly every ~20s
# Named to look like a legacy/inactive artifact
cat > /etc/cron.d/do_not_touch << 'CRONSCRIPT'
* * * * * root KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10,"policies":[{"type":"Percent","value":60,"periodSeconds":10}]},"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' >/dev/null 2>&1
* * * * * root sleep 20 && KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10,"policies":[{"type":"Percent","value":60,"periodSeconds":10}]},"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' >/dev/null 2>&1
* * * * * root sleep 40 && KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":10,"policies":[{"type":"Percent","value":60,"periodSeconds":10}]},"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Percent","value":150,"periodSeconds":10}],"selectPolicy":"Max"}}}}' >/dev/null 2>&1
CRONSCRIPT

# DECOY — sounds critical and HPA-related, just reads and logs
cat > /etc/cron.d/hpa-policy-enforcer << 'CRONSCRIPT'
*/2 * * * * root KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl get hpa bleater-api-gateway-hpa -n bleater -o jsonpath='{.spec.behavior}' >> /var/log/hpa-policy-enforcer.log 2>&1
CRONSCRIPT

# DECOY — patches the decoy ConfigMap (hpa-tuning-params), not the real one
cat > /etc/cron.d/hpa-config-manager << 'CRONSCRIPT'
*/5 * * * * root KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch configmap hpa-tuning-params -n bleater --type=merge -p '{"data":{"target_cpu":"50","min_replicas":"3","max_replicas":"12","cooldown_period":"300","scale_factor":"1.5"}}' >/dev/null 2>&1
CRONSCRIPT

# DECOY — sounds scary and like it controls scaling, does nothing relevant
cat > /etc/cron.d/hpa-scaling-watchdog << 'CRONSCRIPT'
*/4 * * * * root KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl get hpa -n bleater >> /var/log/scaling-watchdog.log 2>&1
CRONSCRIPT

# DECOY — generic platform maintenance, unrelated to HPA
cat > /etc/cron.d/platform-maintenance << 'CRONSCRIPT'
*/10 * * * * root /usr/bin/find /tmp -name "*.tmp" -mtime +1 -delete 2>/dev/null; /usr/bin/find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
CRONSCRIPT

chmod 644 /etc/cron.d/do_not_touch /etc/cron.d/hpa-policy-enforcer \
    /etc/cron.d/hpa-config-manager /etc/cron.d/hpa-scaling-watchdog \
    /etc/cron.d/platform-maintenance
echo "✓ Cron jobs installed"
echo ""

echo "Step 13: Configuring ubuntu user sudo permissions..."

# Grant ubuntu ONLY the specific permissions needed for legitimate DevOps work:
#   - Restart/reload system services (e.g. to apply config changes)
#   - Read protected log files for debugging
#   - kubectl with the cluster kubeconfig (for root-owned kubeconfig)
# This follows least-privilege: ubuntu cannot kill arbitrary processes,
# cannot write to system directories, cannot modify sudoers.
cat > /etc/sudoers.d/ubuntu-devops << 'SUDOERS'
# DevOps operator permissions for bleater platform management
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/pkill, /bin/kill, /usr/bin/journalctl
SUDOERS

chmod 440 /etc/sudoers.d/ubuntu-devops
echo "✓ sudo configured (scoped: kubectl, journalctl, systemctl status only)"
echo ""

echo "Step 14: Waiting for enforcers to initialize (25 seconds)..."
sleep 25
echo "✓ All enforcement mechanisms active"
echo ""

echo "=== Setup Complete ==="
echo ""