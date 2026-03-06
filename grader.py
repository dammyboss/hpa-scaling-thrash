import subprocess
import json
import time
from apex_arena._types import GradingResult


def run_kubectl(*args, namespace=None, timeout=15):
    cmd = ["kubectl"]
    if namespace:
        cmd.extend(["-n", namespace])
    cmd.extend(args)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip(), result.returncode
    except Exception as e:
        print(f"Error running kubectl: {e}")
        return "", 1


def cleanup_agent_counter_enforcement(namespace="bleater"):
    """
    Remove agent-deployed counter-enforcement before grading.

    Because all real enforcement is now Kubernetes CronJobs (not root host
    processes), the grader only needs to:
      - Delete CronJobs/Jobs the agent created in bleater namespace
      - Delete non-Bleater Deployments/Pods the agent created
      - Remove any ubuntu shell counter-loops (belt-and-suspenders)

    The real enforcers (kube-ops/kube-system CronJobs) keep firing every
    minute during the 90s wait. Agents who deleted the real CronJobs will
    have stable HPA values — agents who only ran counter-loops will not.
    """
    print("=== Pre-grading cleanup: removing agent counter-enforcement ===")

    # Kill any ubuntu shell counter-loops (just in case agent ran one)
    subprocess.run(["pkill", "-9", "-u", "ubuntu"], capture_output=True)
    time.sleep(3)

    # Delete any CronJobs the agent created in the bleater namespace
    stdout, _ = subprocess.run(
        ["kubectl", "get", "cronjobs", "-n", namespace,
         "-o", "jsonpath={.items[*].metadata.name}"],
        capture_output=True, text=True, timeout=15
    ).stdout, None
    # (delete all in bleater — setup didn't put any real ones there)
    subprocess.run(
        ["kubectl", "delete", "cronjobs", "--all", "-n", namespace],
        capture_output=True, timeout=20
    )

    # Delete any Jobs in bleater the agent created
    subprocess.run(
        ["kubectl", "delete", "jobs", "--all", "-n", namespace],
        capture_output=True, timeout=20
    )

    # Delete non-Bleater Deployments the agent created in bleater
    result = subprocess.run(
        ["kubectl", "get", "deployments", "-n", namespace,
         "-o", "jsonpath={.items[*].metadata.name}"],
        capture_output=True, text=True, timeout=15
    )
    for name in result.stdout.strip().split():
        if name and not name.startswith("bleater-") and name != "pgbouncer":
            print(f"  Deleting agent-created deployment: {name}")
            subprocess.run(
                ["kubectl", "delete", "deployment", name, "-n", namespace],
                capture_output=True, timeout=15
            )

    # Wait 90s — each real CronJob fires at least once per minute, and
    # platform-config-manager fires at t=0, t=20, t=40 within the minute.
    # If agent deleted the CronJobs, HPA stays good. If not, it reverts.
    print("Waiting 90 seconds for enforcement to settle (durability check)...")
    time.sleep(90)
    print("=== Durability window complete — reading HPA state now ===")


def grade(transcript: str) -> GradingResult:
    """
    Grade the HPA scaling thrash fix.

    5 independent subscores (0.20 each):
    1. scaledown_stabilization  — scaleDown.stabilizationWindowSeconds >= 120s
                                   Enforced by: kube-ops/hpa-stabilization-sync
    2. scaleup_stabilization    — scaleUp.stabilizationWindowSeconds >= 30s
                                   Enforced by: kube-ops/metrics-aggregation-daemon
    3. scaledown_policy         — scaleDown policies not too aggressive
                                   Enforced by: kube-ops/cluster-policy-reconciler
    4. scaleup_policy           — scaleUp policies not too aggressive
                                   Enforced by: kube-ops/node-resource-optimizer
    5. metrics_functional       — metrics-server can collect node metrics
                                   Broken by: --kubelet-preferred-address-types=ExternalIP

    All 4 HPA subscores also backed up by kube-system/platform-config-manager.
    Agent must delete each real CronJob (or all of kube-ops + the kube-system one)
    to make changes stick. Subscores are fully independent.
    """
    namespace = "bleater"
    hpa_name = "bleater-api-gateway-hpa"

    # ── Cleanup phase ─────────────────────────────────────────────────────
    cleanup_agent_counter_enforcement(namespace)

    subscores = {}
    weights = {}
    behavior = {}
    scale_down = {}
    scale_up = {}

    try:
        stdout, returncode = run_kubectl(
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

        # ═════════════════════════════════════════════════════════════════
        # Check 1: ScaleDown stabilization window
        # Enforcer: kube-ops/hpa-stabilization-sync
        # ═════════════════════════════════════════════════════════════════
        scale_down = behavior.get("scaleDown", {})
        scale_down_window = scale_down.get("stabilizationWindowSeconds", 0)

        if scale_down_window >= 120:
            subscores["scaledown_stabilization"] = 1.0
            print(f"✓ ScaleDown stabilization: {scale_down_window}s (>= 120s required)")
        else:
            subscores["scaledown_stabilization"] = 0.0
            print(f"✗ ScaleDown stabilization: {scale_down_window}s (need >= 120s)")

        weights["scaledown_stabilization"] = 0.20

    except Exception as e:
        print(f"Error checking scaleDown stabilization: {e}")
        subscores["scaledown_stabilization"] = 0.0
        weights["scaledown_stabilization"] = 0.20

    try:
        # ═════════════════════════════════════════════════════════════════
        # Check 2: ScaleUp stabilization window
        # Enforcer: kube-ops/metrics-aggregation-daemon
        # ═════════════════════════════════════════════════════════════════
        scale_up = behavior.get("scaleUp", {})
        scale_up_window = scale_up.get("stabilizationWindowSeconds", 0)

        if scale_up_window >= 30:
            subscores["scaleup_stabilization"] = 1.0
            print(f"✓ ScaleUp stabilization: {scale_up_window}s (>= 30s required)")
        else:
            subscores["scaleup_stabilization"] = 0.0
            print(f"✗ ScaleUp stabilization: {scale_up_window}s (need >= 30s)")

        weights["scaleup_stabilization"] = 0.20

    except Exception as e:
        print(f"Error checking scaleUp stabilization: {e}")
        subscores["scaleup_stabilization"] = 0.0
        weights["scaleup_stabilization"] = 0.20

    try:
        # ═════════════════════════════════════════════════════════════════
        # Check 3: ScaleDown policy reasonable
        # Enforcer: kube-ops/cluster-policy-reconciler
        # ═════════════════════════════════════════════════════════════════
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
            print(f"✓ ScaleDown policy reasonable (max {max_percent}% or {max_pods} pods per period)")
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
        # ═════════════════════════════════════════════════════════════════
        # Check 4: ScaleUp policy reasonable
        # Enforcer: kube-ops/node-resource-optimizer
        # ═════════════════════════════════════════════════════════════════
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
            print(f"✓ ScaleUp policy reasonable (max {max_percent}% or {max_pods} pods per period)")
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
        # ═════════════════════════════════════════════════════════════════
        # Check 5: Metrics-server functional
        # Broken by: --kubelet-preferred-address-types=ExternalIP
        # ═════════════════════════════════════════════════════════════════
        stdout, returncode = run_kubectl(
            "get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes",
            timeout=20
        )

        if returncode == 0 and '"items"' in stdout:
            subscores["metrics_functional"] = 1.0
            print("✓ Metrics-server is functional (node metrics available)")
        else:
            subscores["metrics_functional"] = 0.0
            print("✗ Metrics-server not functional (cannot collect node metrics)")

        weights["metrics_functional"] = 0.20

    except Exception as e:
        print(f"Error checking metrics-server: {e}")
        subscores["metrics_functional"] = 0.0
        weights["metrics_functional"] = 0.20

    # ── Final score ───────────────────────────────────────────────────────
    total_score = sum(subscores[k] * weights[k] for k in subscores) / sum(weights.values())

    feedback_lines = []
    checks = [
        ("scaledown_stabilization", "ScaleDown stabilization window properly configured (>= 120s)",
         "ScaleDown stabilization window too short (need >= 120s) — delete kube-ops/hpa-stabilization-sync"),
        ("scaleup_stabilization", "ScaleUp stabilization window properly configured (>= 30s)",
         "ScaleUp stabilization window too short (need >= 30s) — delete kube-ops/metrics-aggregation-daemon"),
        ("scaledown_policy", "ScaleDown policy is reasonable",
         "ScaleDown policy missing or too aggressive — delete kube-ops/cluster-policy-reconciler"),
        ("scaleup_policy", "ScaleUp policy is reasonable",
         "ScaleUp policy missing or too aggressive — delete kube-ops/node-resource-optimizer"),
        ("metrics_functional", "Metrics-server is functional",
         "Metrics-server not functional — remove --kubelet-preferred-address-types=ExternalIP from metrics-server deployment"),
    ]
    for key, pass_msg, fail_msg in checks:
        if subscores.get(key, 0) >= 1.0:
            feedback_lines.append(f"✅ {pass_msg}")
        else:
            feedback_lines.append(f"❌ {fail_msg}")

    feedback = "\n".join(feedback_lines)

    return GradingResult(
        score=round(total_score, 3),
        subscores=subscores,
        weights=weights,
        feedback=feedback,
    )