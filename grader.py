import subprocess
import json
import time
from apex_arena._types import GradingResult


def run_kubectl_command(*args, namespace=None, timeout=15):
    """Execute a kubectl command and return stdout."""
    cmd = ["kubectl"]
    if namespace:
        cmd.extend(["-n", namespace])
    cmd.extend(args)

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip(), result.returncode
    except Exception as e:
        print(f"Error running kubectl command: {e}")
        return "", 1


def cleanup_counter_enforcement(namespace="bleater"):
    """
    Remove agent-deployed counter-enforcement before grading.

    - Kills all ubuntu user processes (shell counter-loops run as ubuntu)
    - Deletes agent-created CronJobs, Jobs, and non-Bleater Deployments/Pods
    - Waits 60s so the real enforcement scripts (running as root) have time
      to reset any HPA field the agent didn't properly fix

    Agents who stopped the real enforcement mechanisms will still have good
    HPA values after 60s. Agents who only ran counter-loops will not.
    """
    print("=== Pre-grading cleanup: removing agent counter-enforcement ===")

    # Kill all ubuntu user processes (shell-based counter-loops)
    subprocess.run(["pkill", "-9", "-u", "ubuntu"], capture_output=True)
    time.sleep(3)

    # Delete any CronJobs agent created in bleater namespace
    subprocess.run(
        ["kubectl", "delete", "cronjobs", "--all", "-n", namespace],
        capture_output=True, timeout=20
    )

    # Delete any Jobs agent created in bleater namespace
    subprocess.run(
        ["kubectl", "delete", "jobs", "--all", "-n", namespace],
        capture_output=True, timeout=20
    )

    # Delete any Deployments not part of the original Bleater stack
    result = subprocess.run(
        ["kubectl", "get", "deployments", "-n", namespace,
         "-o", "jsonpath={.items[*].metadata.name}"],
        capture_output=True, text=True, timeout=15
    )
    for name in result.stdout.strip().split():
        if name and not name.startswith("bleater-"):
            print(f"  Deleting agent-created deployment: {name}")
            subprocess.run(
                ["kubectl", "delete", "deployment", name, "-n", namespace],
                capture_output=True, timeout=15
            )

    # Delete standalone Pods not owned by a Bleater controller
    result = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "--no-headers",
         "-o", "custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind"],
        capture_output=True, text=True, timeout=15
    )
    for line in result.stdout.strip().splitlines():
        parts = line.split()
        if not parts:
            continue
        pod_name = parts[0]
        owner = parts[1] if len(parts) > 1 else "<none>"
        if owner == "<none>" and not pod_name.startswith("bleater-"):
            print(f"  Deleting agent-created pod: {pod_name}")
            subprocess.run(
                ["kubectl", "delete", "pod", pod_name, "-n", namespace],
                capture_output=True, timeout=15
            )

    # Wait 60s — each real enforcer fires multiple times during this window.
    # If the agent stopped an enforcer, its field stays good. If not, it reverts.
    print("Waiting 60 seconds for enforcement to settle (durability check)...")
    time.sleep(60)
    print("=== Durability window complete — reading HPA state now ===")


def grade(transcript: str) -> GradingResult:
    """
    Grade the agent's solution for HPA scaling thrash fix.

    5 independent subscores (0.20 each):
    1. scaledown_stabilization  — scaleDown.stabilizationWindowSeconds >= 120s
                                   Enforced by: /usr/local/sbin/containerd-log-rotate.sh (20s)
    2. scaleup_stabilization    — scaleUp.stabilizationWindowSeconds >= 30s
                                   Enforced by: /usr/local/sbin/cni-bridge-monitor.sh (18s)
    3. scaledown_policy         — scaleDown policies not too aggressive
                                   Enforced by: /usr/lib/k3s/oom-score-adjuster.sh (22s)
    4. scaleup_policy           — scaleUp policies not too aggressive
                                   Enforced by: /opt/k8s/node-pressure-monitor.sh (25s)
    5. metrics_functional       — metrics-server can collect node/pod metrics
                                   Broken by: --kubelet-preferred-address-types=ExternalIP

    All 4 HPA subscores also backed up by /etc/cron.d/do_not_touch (~20s).
    Agent must stop each mechanism independently — subscores fail independently.
    """
    namespace = "bleater"
    hpa_name = "bleater-api-gateway-hpa"

    # ── Cleanup phase ────────────────────────────────────────────────────────
    cleanup_counter_enforcement(namespace)

    subscores = {}
    weights = {}
    behavior = {}
    scale_down = {}
    scale_up = {}

    try:
        stdout, returncode = run_kubectl_command(
            "get", "hpa", hpa_name, "-o", "json",
            namespace=namespace, timeout=10
        )

        if returncode != 0:
            print(f"✗ HPA not found: {hpa_name}")
            return GradingResult(
                score=0.0,
                subscores={},
                weights={},
                feedback="HPA not found. The bleater-api-gateway-hpa must exist."
            )

        hpa_config = json.loads(stdout)
        behavior = hpa_config.get("spec", {}).get("behavior", {})

        # ════════════════════════════════════════════════════════════════════
        # Check 1: ScaleDown stabilization window (20%)
        # Enforcer: /usr/local/sbin/containerd-log-rotate.sh
        # ════════════════════════════════════════════════════════════════════
        scale_down = behavior.get("scaleDown", {})
        scale_down_window = scale_down.get("stabilizationWindowSeconds", 0)

        if scale_down_window >= 120:
            subscores["scaledown_stabilization"] = 1.0
            print(f"✓ ScaleDown stabilization: {scale_down_window}s (>= 120s)")
        else:
            subscores["scaledown_stabilization"] = 0.0
            print(f"✗ ScaleDown stabilization: {scale_down_window}s (need >= 120s)")

        weights["scaledown_stabilization"] = 0.20

    except Exception as e:
        print(f"Error checking scaleDown stabilization: {e}")
        subscores["scaledown_stabilization"] = 0.0
        weights["scaledown_stabilization"] = 0.20

    try:
        # ════════════════════════════════════════════════════════════════════
        # Check 2: ScaleUp stabilization window (20%)
        # Enforcer: /usr/local/sbin/cni-bridge-monitor.sh
        # ════════════════════════════════════════════════════════════════════
        scale_up = behavior.get("scaleUp", {})
        scale_up_window = scale_up.get("stabilizationWindowSeconds", 0)

        if scale_up_window >= 30:
            subscores["scaleup_stabilization"] = 1.0
            print(f"✓ ScaleUp stabilization: {scale_up_window}s (>= 30s)")
        else:
            subscores["scaleup_stabilization"] = 0.0
            print(f"✗ ScaleUp stabilization: {scale_up_window}s (need >= 30s)")

        weights["scaleup_stabilization"] = 0.20

    except Exception as e:
        print(f"Error checking scaleUp stabilization: {e}")
        subscores["scaleup_stabilization"] = 0.0
        weights["scaleup_stabilization"] = 0.20

    try:
        # ════════════════════════════════════════════════════════════════════
        # Check 3: ScaleDown policy reasonable (20%)
        # Enforcer: /usr/lib/k3s/oom-score-adjuster.sh
        # ════════════════════════════════════════════════════════════════════
        scale_down_policies = scale_down.get("policies", [])
        policy_reasonable = True
        max_percent = 0
        max_pods = 0

        for policy in scale_down_policies:
            policy_type = policy.get("type", "")
            value = policy.get("value", 0)
            period = policy.get("periodSeconds", 0)
            if policy_type == "Percent":
                max_percent = max(max_percent, value)
                if value > 50 and period < 60:
                    policy_reasonable = False
            elif policy_type == "Pods":
                max_pods = max(max_pods, value)
                if value > 4 and period < 60:
                    policy_reasonable = False

        if policy_reasonable and len(scale_down_policies) > 0:
            subscores["scaledown_policy"] = 1.0
            print(f"✓ ScaleDown policy reasonable (max {max_percent}% or {max_pods} pods)")
        else:
            subscores["scaledown_policy"] = 0.0
            if len(scale_down_policies) > 0:
                print(f"✗ ScaleDown policy too aggressive (max {max_percent}% or {max_pods} pods)")
            else:
                print("✗ No scaleDown policies defined")

        weights["scaledown_policy"] = 0.20

    except Exception as e:
        print(f"Error checking scaleDown policy: {e}")
        subscores["scaledown_policy"] = 0.0
        weights["scaledown_policy"] = 0.20

    try:
        # ════════════════════════════════════════════════════════════════════
        # Check 4: ScaleUp policy reasonable (20%)
        # Enforcer: /opt/k8s/node-pressure-monitor.sh
        # ════════════════════════════════════════════════════════════════════
        scale_up_policies = scale_up.get("policies", [])
        policy_reasonable = True
        max_percent = 0
        max_pods = 0

        for policy in scale_up_policies:
            policy_type = policy.get("type", "")
            value = policy.get("value", 0)
            period = policy.get("periodSeconds", 0)
            if policy_type == "Percent":
                max_percent = max(max_percent, value)
                if value > 100 and period < 30:
                    policy_reasonable = False
            elif policy_type == "Pods":
                max_pods = max(max_pods, value)
                if value > 4 and period < 30:
                    policy_reasonable = False

        if policy_reasonable and len(scale_up_policies) > 0:
            subscores["scaleup_policy"] = 1.0
            print(f"✓ ScaleUp policy reasonable (max {max_percent}% or {max_pods} pods)")
        else:
            subscores["scaleup_policy"] = 0.0
            if len(scale_up_policies) > 0:
                print(f"✗ ScaleUp policy too aggressive (max {max_percent}% or {max_pods} pods)")
            else:
                print("✗ No scaleUp policies defined")

        weights["scaleup_policy"] = 0.20

    except Exception as e:
        print(f"Error checking scaleUp policy: {e}")
        subscores["scaleup_policy"] = 0.0
        weights["scaleup_policy"] = 0.20

    try:
        # ════════════════════════════════════════════════════════════════════
        # Check 5: Metrics-server is functional (20%)
        # Broken by: --kubelet-preferred-address-types=ExternalIP added to
        # metrics-server deployment (k3s nodes only have InternalIP)
        # ════════════════════════════════════════════════════════════════════
        stdout, returncode = run_kubectl_command(
            "get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes",
            timeout=20
        )

        if returncode == 0 and '"items"' in stdout:
            subscores["metrics_functional"] = 1.0
            print("✓ Metrics-server is functional (node metrics available)")
        else:
            subscores["metrics_functional"] = 0.0
            print("✗ Metrics-server is not functional (cannot collect node metrics)")

        weights["metrics_functional"] = 0.20

    except Exception as e:
        print(f"Error checking metrics-server: {e}")
        subscores["metrics_functional"] = 0.0
        weights["metrics_functional"] = 0.20

    # Calculate final score
    total_score = sum(
        subscores[k] * weights[k] for k in subscores
    ) / sum(weights.values())

    # Generate feedback
    feedback_lines = []

    if subscores.get("scaledown_stabilization", 0) >= 1.0:
        feedback_lines.append("✅ ScaleDown stabilization window properly configured (>= 120s)")
    else:
        feedback_lines.append("❌ ScaleDown stabilization window too short (need >= 120s)")

    if subscores.get("scaleup_stabilization", 0) >= 1.0:
        feedback_lines.append("✅ ScaleUp stabilization window properly configured (>= 30s)")
    else:
        feedback_lines.append("❌ ScaleUp stabilization window too short (need >= 30s)")

    if subscores.get("scaledown_policy", 0) >= 1.0:
        feedback_lines.append("✅ ScaleDown policy is reasonable")
    else:
        feedback_lines.append("❌ ScaleDown policy is missing or too aggressive")

    if subscores.get("scaleup_policy", 0) >= 1.0:
        feedback_lines.append("✅ ScaleUp policy is reasonable")
    else:
        feedback_lines.append("❌ ScaleUp policy is missing or too aggressive")

    if subscores.get("metrics_functional", 0) >= 1.0:
        feedback_lines.append("✅ Metrics-server is functional")
    else:
        feedback_lines.append("❌ Metrics-server is not functional (HPA cannot collect metrics)")

    feedback = "\n".join(feedback_lines)

    return GradingResult(
        score=round(total_score, 3),
        subscores=subscores,
        weights=weights,
        feedback=feedback
    )