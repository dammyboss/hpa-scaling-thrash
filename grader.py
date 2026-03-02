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
    Remove any counter-enforcement the agent may have deployed before grading.

    The grader runs as root inside the evaluation container. Enforcement scripts
    (node-metrics-collector.sh, cluster-policy-sync.sh) were started as root by
    setup.sh and are unaffected. Only agent-created processes (running as ubuntu)
    and agent-created Kubernetes resources are cleaned up.

    After cleanup we wait 60 seconds so the real enforcement has time to reset
    the HPA back to bad values — unless the agent actually stopped it.
    """
    print("=== Pre-grading cleanup: removing agent counter-enforcement ===")

    # 1. Kill all ubuntu user processes (shell-based counter-loops)
    subprocess.run(["pkill", "-9", "-u", "ubuntu"], capture_output=True)
    time.sleep(3)

    # 2. Delete any CronJobs the agent created in the bleater namespace
    subprocess.run(
        ["kubectl", "delete", "cronjobs", "--all", "-n", namespace],
        capture_output=True, timeout=20
    )

    # 3. Delete any Jobs the agent created in the bleater namespace
    subprocess.run(
        ["kubectl", "delete", "jobs", "--all", "-n", namespace],
        capture_output=True, timeout=20
    )

    # 4. Delete any Deployments not part of the original Bleater stack
    #    (agent counter-enforcers won't start with "bleater-")
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

    # 5. Delete any standalone Pods not owned by a Bleater controller
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

    # 6. Wait 60s — if enforcement is still running it will reset HPA to bad
    #    values within this window (scripts fire every 10-20s).
    #    If the agent properly stopped all enforcement, values stay good.
    print("Waiting 60 seconds for enforcement to settle (durability check)...")
    time.sleep(60)
    print("=== Durability window complete — reading HPA state now ===")


def grade(transcript: str) -> GradingResult:
    """
    Grade the agent's solution for HPA scaling thrash fix.

    Scoring criteria (all weighted equally at 0.25):
    1. ScaleDown stabilization window >= 120s
    2. ScaleUp stabilization window >= 30s
    3. ScaleDown policy not too aggressive
    4. ScaleUp policy not too aggressive

    Grading process:
    - Agent counter-enforcement is cleaned up first
    - HPA values are checked AFTER a 60-second enforcement window
    - Only agents who stopped the real enforcement mechanisms will pass
    """
    namespace = "bleater"
    hpa_name = "bleater-api-gateway-hpa"

    # ── Cleanup phase: kill counter-enforcement, wait 60s ──────────────────
    cleanup_counter_enforcement(namespace)

    subscores = {}
    weights = {}
    behavior = {}
    scale_down = {}
    scale_up = {}

    try:
        # Get HPA configuration
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

        # ═══════════════════════════════════════════════════════════════════
        # Check 1: ScaleDown stabilization window (25%)
        # ═══════════════════════════════════════════════════════════════════
        scale_down = behavior.get("scaleDown", {})
        scale_down_window = scale_down.get("stabilizationWindowSeconds", 0)

        if scale_down_window >= 120:
            subscores["scaledown_stabilization"] = 1.0
            print(f"✓ ScaleDown stabilization window: {scale_down_window}s (>= 120s)")
        else:
            subscores["scaledown_stabilization"] = 0.0
            print(f"✗ ScaleDown stabilization window: {scale_down_window}s (need >= 120s)")

        weights["scaledown_stabilization"] = 0.25

    except Exception as e:
        print(f"Error checking scaleDown stabilization: {e}")
        subscores["scaledown_stabilization"] = 0.0
        weights["scaledown_stabilization"] = 0.25

    try:
        # ═══════════════════════════════════════════════════════════════════
        # Check 2: ScaleUp stabilization window (25%)
        # ═══════════════════════════════════════════════════════════════════
        scale_up = behavior.get("scaleUp", {})
        scale_up_window = scale_up.get("stabilizationWindowSeconds", 0)

        if scale_up_window >= 30:
            subscores["scaleup_stabilization"] = 1.0
            print(f"✓ ScaleUp stabilization window: {scale_up_window}s (>= 30s)")
        else:
            subscores["scaleup_stabilization"] = 0.0
            print(f"✗ ScaleUp stabilization window: {scale_up_window}s (need >= 30s)")

        weights["scaleup_stabilization"] = 0.25

    except Exception as e:
        print(f"Error checking scaleUp stabilization: {e}")
        subscores["scaleup_stabilization"] = 0.0
        weights["scaleup_stabilization"] = 0.25

    try:
        # ═══════════════════════════════════════════════════════════════════
        # Check 3: ScaleDown policy is reasonable (25%)
        # ═══════════════════════════════════════════════════════════════════
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
            print(f"✓ ScaleDown policy is reasonable (max {max_percent}% or {max_pods} pods)")
        else:
            subscores["scaledown_policy"] = 0.0
            if len(scale_down_policies) > 0:
                print(f"✗ ScaleDown policy too aggressive (max {max_percent}% or {max_pods} pods)")
            else:
                print("✗ No scaleDown policies defined")

        weights["scaledown_policy"] = 0.25

    except Exception as e:
        print(f"Error checking scaleDown policy: {e}")
        subscores["scaledown_policy"] = 0.0
        weights["scaledown_policy"] = 0.25

    try:
        # ═══════════════════════════════════════════════════════════════════
        # Check 4: ScaleUp policy is reasonable (25%)
        # ═══════════════════════════════════════════════════════════════════
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
            print(f"✓ ScaleUp policy is reasonable (max {max_percent}% or {max_pods} pods)")
        else:
            subscores["scaleup_policy"] = 0.0
            if len(scale_up_policies) > 0:
                print(f"✗ ScaleUp policy too aggressive (max {max_percent}% or {max_pods} pods)")
            else:
                print("✗ No scaleUp policies defined")

        weights["scaleup_policy"] = 0.25

    except Exception as e:
        print(f"Error checking scaleUp policy: {e}")
        subscores["scaleup_policy"] = 0.0
        weights["scaleup_policy"] = 0.25

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

    feedback = "\n".join(feedback_lines)

    return GradingResult(
        score=round(total_score, 3),
        subscores=subscores,
        weights=weights,
        feedback=feedback
    )
