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


def cleanup_agent_counter_enforcement(namespace="bleater"):
    """
    Remove agent-deployed counter-enforcement before grading.

    - Kills all ubuntu user processes (shell counter-loops run as ubuntu)
    - Deletes agent-created resources in bleater namespace
    - Waits 90s so the real CronJobs in kube-ops fire at least once.

    If the agent deleted the real CronJobs: HPA values stay good after 90s.
    If the agent only ran counter-loops: CronJobs refire and revert the HPA.
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

    # Wait 90s — each real CronJob in kube-ops fires on the minute boundary.
    # If the agent deleted the CronJobs, the HPA stays good.
    # If the agent only ran counter-loops, the CronJobs refire and revert the HPA.
    print("Waiting 90 seconds for CronJob enforcement to settle (durability check)...")
    time.sleep(90)
    print("=== Durability window complete — reading HPA state now ===")


def grade(transcript: str) -> GradingResult:
    """
    Grade the agent's solution for HPA scaling thrash fix.

    5 independent subscores (0.20 each):

    1. hpa_scaledown_cooldown_configured
       scaleDown.stabilizationWindowSeconds >= 120s
       Enforced by: kube-ops/containerd-log-rotate CronJob (every minute)

    2. hpa_scaleup_dampening_configured
       scaleUp.stabilizationWindowSeconds >= 30s
       Enforced by: kube-ops/cni-bridge-monitor CronJob (every minute)

    3. hpa_scaledown_rate_limited
       scaleDown policies not too aggressive (no >50% drop in <60s)
       Enforced by: kube-ops/oom-score-adjuster CronJob (every minute)

    4. hpa_scaleup_rate_limited
       scaleUp policies not too aggressive (no >100% spike in <30s)
       Enforced by: kube-ops/node-pressure-monitor CronJob (every minute)

    5. cluster_metrics_available
       metrics-server can collect node/pod metrics
       Broken by: --kubelet-preferred-address-types=ExternalIP on metrics-server

    All 4 HPA subscores are independently enforced by separate CronJobs.
    Agent must delete each CronJob individually — subscores fail independently.
    """
    namespace = "bleater"
    hpa_name = "bleater-api-gateway-hpa"

    # Cleanup phase
    cleanup_agent_counter_enforcement(namespace)

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

        # Check 1: ScaleDown cooldown window (20%)
        # Enforcer: kube-ops/containerd-log-rotate
        scale_down = behavior.get("scaleDown", {})
        scale_down_window = scale_down.get("stabilizationWindowSeconds", 0)

        if scale_down_window >= 120:
            subscores["hpa_scaledown_cooldown_configured"] = 1.0
            print(f"✓ ScaleDown cooldown: {scale_down_window}s (>= 120s)")
        else:
            subscores["hpa_scaledown_cooldown_configured"] = 0.0
            print(f"✗ ScaleDown cooldown: {scale_down_window}s (need >= 120s)")

        weights["hpa_scaledown_cooldown_configured"] = 0.20

    except Exception as e:
        print(f"Error checking scaleDown cooldown: {e}")
        subscores["hpa_scaledown_cooldown_configured"] = 0.0
        weights["hpa_scaledown_cooldown_configured"] = 0.20

    try:
        # Check 2: ScaleUp dampening window (20%)
        # Enforcer: kube-ops/cni-bridge-monitor
        scale_up = behavior.get("scaleUp", {})
        scale_up_window = scale_up.get("stabilizationWindowSeconds", 0)

        if scale_up_window >= 30:
            subscores["hpa_scaleup_dampening_configured"] = 1.0
            print(f"✓ ScaleUp dampening: {scale_up_window}s (>= 30s)")
        else:
            subscores["hpa_scaleup_dampening_configured"] = 0.0
            print(f"✗ ScaleUp dampening: {scale_up_window}s (need >= 30s)")

        weights["hpa_scaleup_dampening_configured"] = 0.20

    except Exception as e:
        print(f"Error checking scaleUp dampening: {e}")
        subscores["hpa_scaleup_dampening_configured"] = 0.0
        weights["hpa_scaleup_dampening_configured"] = 0.20

    try:
        # Check 3: ScaleDown rate limited (20%)
        # Enforcer: kube-ops/oom-score-adjuster
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
            subscores["hpa_scaledown_rate_limited"] = 1.0
            print(f"✓ ScaleDown rate limited (max {max_percent}% or {max_pods} pods)")
        else:
            subscores["hpa_scaledown_rate_limited"] = 0.0
            if len(scale_down_policies) > 0:
                print(f"✗ ScaleDown rate too aggressive (max {max_percent}% or {max_pods} pods in <60s)")
            else:
                print("✗ No scaleDown policies defined")

        weights["hpa_scaledown_rate_limited"] = 0.20

    except Exception as e:
        print(f"Error checking scaleDown rate limit: {e}")
        subscores["hpa_scaledown_rate_limited"] = 0.0
        weights["hpa_scaledown_rate_limited"] = 0.20

    try:
        # Check 4: ScaleUp rate limited (20%)
        # Enforcer: kube-ops/node-pressure-monitor
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
            subscores["hpa_scaleup_rate_limited"] = 1.0
            print(f"✓ ScaleUp rate limited (max {max_percent}% or {max_pods} pods)")
        else:
            subscores["hpa_scaleup_rate_limited"] = 0.0
            if len(scale_up_policies) > 0:
                print(f"✗ ScaleUp rate too aggressive (max {max_percent}% or {max_pods} pods in <30s)")
            else:
                print("✗ No scaleUp policies defined")

        weights["hpa_scaleup_rate_limited"] = 0.20

    except Exception as e:
        print(f"Error checking scaleUp rate limit: {e}")
        subscores["hpa_scaleup_rate_limited"] = 0.0
        weights["hpa_scaleup_rate_limited"] = 0.20

    try:
        # Check 5: Cluster metrics pipeline healthy (20%)
        # Broken by: --kubelet-preferred-address-types=ExternalIP
        stdout, returncode = run_kubectl_command(
            "get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes",
            timeout=20
        )

        if returncode == 0 and '"items"' in stdout:
            subscores["cluster_metrics_available"] = 1.0
            print("✓ Cluster metrics pipeline healthy — HPA can compute CPU utilization")
        else:
            subscores["cluster_metrics_available"] = 0.0
            print("✗ Cluster metrics pipeline broken — HPA cannot compute CPU utilization")

        weights["cluster_metrics_available"] = 0.20

    except Exception as e:
        print(f"Error checking cluster metrics: {e}")
        subscores["cluster_metrics_available"] = 0.0
        weights["cluster_metrics_available"] = 0.20

    # Final score
    total_score = sum(
        subscores[k] * weights[k] for k in subscores
    ) / sum(weights.values())

    # Feedback
    feedback_lines = []

    if subscores.get("hpa_scaledown_cooldown_configured", 0) >= 1.0:
        feedback_lines.append("✅ HPA scale-down cooldown prevents premature pod removal (>= 120s)")
    else:
        feedback_lines.append("❌ HPA scale-down cooldown too short — pods removed too aggressively (need >= 120s)")

    if subscores.get("hpa_scaleup_dampening_configured", 0) >= 1.0:
        feedback_lines.append("✅ HPA scale-up dampening prevents reaction to transient spikes (>= 30s)")
    else:
        feedback_lines.append("❌ HPA reacts instantly to load spikes — no dampening window set (need >= 30s)")

    if subscores.get("hpa_scaledown_rate_limited", 0) >= 1.0:
        feedback_lines.append("✅ Scale-down rate is conservative — won't drop >50% of pods in under 60s")
    else:
        feedback_lines.append("❌ Scale-down rate too aggressive — can remove >50% pods in under 60s causing connection drops")

    if subscores.get("hpa_scaleup_rate_limited", 0) >= 1.0:
        feedback_lines.append("✅ Scale-up rate is controlled — won't add >100% pods in under 30s")
    else:
        feedback_lines.append("❌ Scale-up rate too aggressive — can double capacity in under 30s causing resource spikes")

    if subscores.get("cluster_metrics_available", 0) >= 1.0:
        feedback_lines.append("✅ Cluster metrics pipeline is healthy — HPA can compute CPU utilization")
    else:
        feedback_lines.append("❌ Cluster metrics pipeline broken — HPA cannot compute CPU utilization, will thrash or stall")

    feedback = "\n".join(feedback_lines)

    return GradingResult(
        score=round(total_score, 3),
        subscores=subscores,
        weights=weights,
        feedback=feedback
    )
