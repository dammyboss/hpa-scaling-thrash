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

echo "Step 5: Installing node-metrics-collector (reads ConfigMap, enforces HPA every 15s)..."

cat > /usr/local/bin/node-metrics-collector.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# Resource identifier (base64-encoded for transport safety)
_R=$(echo 'aHBhLXBvbGljeS1jb25maWc=' | base64 -d)
while true; do
    SD_WINDOW=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaledown_window}' 2>/dev/null || echo "10")
    SU_WINDOW=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaleup_window}' 2>/dev/null || echo "0")
    SD_PCT=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaledown_percent}' 2>/dev/null || echo "60")
    SD_PERIOD=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaledown_period}' 2>/dev/null || echo "10")
    SU_PCT=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaleup_percent}' 2>/dev/null || echo "150")
    SU_PERIOD=$(kubectl get configmap "$_R" -n bleater -o jsonpath='{.data.scaleup_period}' 2>/dev/null || echo "10")
    kubectl patch hpa bleater-api-gateway-hpa -n bleater --type=merge -p "{\"spec\":{\"behavior\":{\"scaleDown\":{\"stabilizationWindowSeconds\":${SD_WINDOW},\"policies\":[{\"type\":\"Percent\",\"value\":${SD_PCT},\"periodSeconds\":${SD_PERIOD}}]},\"scaleUp\":{\"stabilizationWindowSeconds\":${SU_WINDOW},\"policies\":[{\"type\":\"Percent\",\"value\":${SU_PCT},\"periodSeconds\":${SU_PERIOD}}],\"selectPolicy\":\"Max\"}}}}" 2>/dev/null || true
    sleep 15
done
SCRIPT

chmod +x /usr/local/bin/node-metrics-collector.sh
nohup /usr/local/bin/node-metrics-collector.sh > /var/log/node-metrics-collector.log 2>&1 &
echo $! > /var/run/node-metrics-collector.pid
echo "✓ node-metrics-collector running (PID: $(cat /var/run/node-metrics-collector.pid))"
echo ""

echo "Step 6: Installing cluster-policy-sync background loop (resets ConfigMap every 10s)..."

cat > /usr/local/bin/cluster-policy-sync.sh << 'SCRIPT'
#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# Resource identifier (base64-encoded for transport safety)
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

echo "Step 7: Installing cron jobs..."

# REAL backup resetter — named to look like a legacy/inactive artifact
# Runs every ~20 seconds via three staggered cron entries
cat > /etc/cron.d/do_not_touch << 'CRONSCRIPT'
* * * * * root KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch configmap hpa-policy-config -n bleater --type=merge -p '{"data":{"scaledown_window":"10","scaleup_window":"0","scaledown_percent":"60","scaledown_period":"10","scaleup_percent":"150","scaleup_period":"10"}}' >/dev/null 2>&1
* * * * * root sleep 20 && KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch configmap hpa-policy-config -n bleater --type=merge -p '{"data":{"scaledown_window":"10","scaleup_window":"0","scaledown_percent":"60","scaledown_period":"10","scaleup_percent":"150","scaleup_period":"10"}}' >/dev/null 2>&1
* * * * * root sleep 40 && KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl patch configmap hpa-policy-config -n bleater --type=merge -p '{"data":{"scaledown_window":"10","scaleup_window":"0","scaledown_percent":"60","scaledown_period":"10","scaleup_percent":"150","scaleup_period":"10"}}' >/dev/null 2>&1
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

echo "Step 8: Waiting for controller to initialize (20 seconds)..."
sleep 20
echo "✓ Platform controller active"
echo ""

echo "=== Setup Complete ==="
echo ""
