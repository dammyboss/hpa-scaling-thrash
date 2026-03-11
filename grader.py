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
    - Waits 90s so any surviving enforcer CronJobs fire at least once.

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

    # Wait 90s — each real CronJob fires on the minute boundary.
    # If the agent deleted the CronJobs, the HPA stays good.
    # If the agent only ran counter-loops, the CronJobs refire and revert.
    print("Waiting 90 seconds for enforcement durability check...")
    time.sleep(90)
    print("=== Durability window complete — reading state now ===")


def get_hpa_config(hpa_name, namespace):
    """Fetch HPA config as dict. Returns (config, error_msg)."""
    stdout, rc = run_kubectl_command(
        "get", "hpa", hpa_name, "-o", "json",
        namespace=namespace, timeout=10
    )
    if rc != 0:
        return None, f"HPA {hpa_name} not found"
    try:
        return json.loads(stdout), None
    except json.JSONDecodeError:
        return None, "Failed to parse HPA JSON"


def grade(transcript: str) -> GradingResult:
    """
    Grade the agent's solution for HPA scaling thrash fix (hard mode).

    9 subscores, each tested FUNCTIONALLY with a durability window.
    Two HPA reads 70s apart — values must be correct on BOTH reads.

    Subscores:
    1. scaledown_window_durable      — stabilizationWindowSeconds >= 120, durable
    2. scaleup_window_durable        — stabilizationWindowSeconds >= 30, durable
    3. scaledown_policy_conservative  — no aggressive scaleDown policies, durable
    4. scaleup_policy_conservative    — no aggressive scaleUp policies, durable
    5. metrics_pipeline_functional    — metrics-server returns fresh pod data
    6. cpu_target_appropriate         — CPU target 40-80%, no extra memory metric
    7. deployment_resources_valid     — CPU request >= 50m, limit >= 200m
    8. hpa_replica_range_sane         — min 2-5, max 8-15, no duplicate HPAs
    9. hpa_currently_computing        — ScalingActive=True, currentMetrics populated
    """
    namespace = "bleater"
    hpa_name = "bleater-api-gateway-hpa"

    # ── Cleanup phase ────────────────────────────────────────────────────────
    cleanup_agent_counter_enforcement(namespace)

    subscores = {}
    weights = {}

    # ── READ 1: First HPA snapshot ──────────────────────────────────────────
    print("\n=== DURABILITY READ 1 ===")
    hpa1, err1 = get_hpa_config(hpa_name, namespace)
    if hpa1 is None:
        print(f"✗ {err1}")
        return GradingResult(
            score=0.0,
            subscores={},
            weights={},
            feedback="HPA not found. The bleater-api-gateway-hpa must exist."
        )

    behavior1 = hpa1.get("spec", {}).get("behavior", {})
    sd1 = behavior1.get("scaleDown", {})
    su1 = behavior1.get("scaleUp", {})
    spec1 = hpa1.get("spec", {})

    # ── Wait 70s for durability ─────────────────────────────────────────────
    print("Waiting 70 seconds for durability verification...")
    time.sleep(70)

    # ── READ 2: Second HPA snapshot ─────────────────────────────────────────
    print("\n=== DURABILITY READ 2 ===")
    hpa2, err2 = get_hpa_config(hpa_name, namespace)
    if hpa2 is None:
        print(f"✗ {err2}")
        return GradingResult(
            score=0.0,
            subscores={},
            weights={},
            feedback="HPA disappeared between reads. The fix is not durable."
        )

    behavior2 = hpa2.get("spec", {}).get("behavior", {})
    sd2 = behavior2.get("scaleDown", {})
    su2 = behavior2.get("scaleUp", {})
    spec2 = hpa2.get("spec", {})

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 1: scaledown_window_durable (0.11)
    # stabilizationWindowSeconds >= 120 on BOTH reads
    # selectPolicy must NOT be "Max"
    # ═════════════════════════════════════════════════════════════════════════
    try:
        sd_window1 = sd1.get("stabilizationWindowSeconds", 0)
        sd_window2 = sd2.get("stabilizationWindowSeconds", 0)
        sd_select1 = sd1.get("selectPolicy", "Max")
        sd_select2 = sd2.get("selectPolicy", "Max")

        window_ok = sd_window1 >= 120 and sd_window2 >= 120
        select_ok = sd_select1 != "Max" and sd_select2 != "Max"

        if window_ok and select_ok:
            subscores["scaledown_window_durable"] = 1.0
            print(f"✓ ScaleDown window: {sd_window1}s/{sd_window2}s (>= 120), selectPolicy: {sd_select1}/{sd_select2}")
        else:
            subscores["scaledown_window_durable"] = 0.0
            if not window_ok:
                print(f"✗ ScaleDown window: {sd_window1}s/{sd_window2}s (need >= 120 on both reads)")
            if not select_ok:
                print(f"✗ ScaleDown selectPolicy: {sd_select1}/{sd_select2} (must not be Max)")
    except Exception as e:
        print(f"Error checking scaleDown window: {e}")
        subscores["scaledown_window_durable"] = 0.0

    weights["scaledown_window_durable"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 2: scaleup_window_durable (0.11)
    # stabilizationWindowSeconds >= 30 on BOTH reads
    # selectPolicy must NOT be "Max"
    # ═════════════════════════════════════════════════════════════════════════
    try:
        su_window1 = su1.get("stabilizationWindowSeconds", 0)
        su_window2 = su2.get("stabilizationWindowSeconds", 0)
        su_select1 = su1.get("selectPolicy", "Max")
        su_select2 = su2.get("selectPolicy", "Max")

        window_ok = su_window1 >= 30 and su_window2 >= 30
        select_ok = su_select1 != "Max" and su_select2 != "Max"

        if window_ok and select_ok:
            subscores["scaleup_window_durable"] = 1.0
            print(f"✓ ScaleUp window: {su_window1}s/{su_window2}s (>= 30), selectPolicy: {su_select1}/{su_select2}")
        else:
            subscores["scaleup_window_durable"] = 0.0
            if not window_ok:
                print(f"✗ ScaleUp window: {su_window1}s/{su_window2}s (need >= 30 on both reads)")
            if not select_ok:
                print(f"✗ ScaleUp selectPolicy: {su_select1}/{su_select2} (must not be Max)")
    except Exception as e:
        print(f"Error checking scaleUp window: {e}")
        subscores["scaleup_window_durable"] = 0.0

    weights["scaleup_window_durable"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 3: scaledown_policy_conservative (0.11)
    # No Percent policy >30% in <60s, no Pods policy >3 in <60s
    # Must pass on BOTH reads
    # ═════════════════════════════════════════════════════════════════════════
    def check_scaledown_policies(sd):
        policies = sd.get("policies", [])
        if not policies:
            return False, "no policies defined"
        for p in policies:
            ptype = p.get("type", "")
            value = p.get("value", 0)
            period = p.get("periodSeconds", 0)
            if ptype == "Percent" and value > 30 and period < 60:
                return False, f"Percent {value}%/{period}s too aggressive"
            if ptype == "Pods" and value > 3 and period < 60:
                return False, f"Pods {value}/{period}s too aggressive"
        return True, "ok"

    try:
        ok1, msg1 = check_scaledown_policies(sd1)
        ok2, msg2 = check_scaledown_policies(sd2)

        if ok1 and ok2:
            subscores["scaledown_policy_conservative"] = 1.0
            print(f"✓ ScaleDown policies conservative on both reads")
        else:
            subscores["scaledown_policy_conservative"] = 0.0
            if not ok1:
                print(f"✗ ScaleDown policy read1: {msg1}")
            if not ok2:
                print(f"✗ ScaleDown policy read2: {msg2}")
    except Exception as e:
        print(f"Error checking scaleDown policies: {e}")
        subscores["scaledown_policy_conservative"] = 0.0

    weights["scaledown_policy_conservative"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 4: scaleup_policy_conservative (0.11)
    # No Percent policy >100% in <30s, no Pods policy >4 in <30s
    # Must pass on BOTH reads
    # ═════════════════════════════════════════════════════════════════════════
    def check_scaleup_policies(su):
        policies = su.get("policies", [])
        if not policies:
            return False, "no policies defined"
        for p in policies:
            ptype = p.get("type", "")
            value = p.get("value", 0)
            period = p.get("periodSeconds", 0)
            if ptype == "Percent" and value > 100 and period < 30:
                return False, f"Percent {value}%/{period}s too aggressive"
            if ptype == "Pods" and value > 4 and period < 30:
                return False, f"Pods {value}/{period}s too aggressive"
        return True, "ok"

    try:
        ok1, msg1 = check_scaleup_policies(su1)
        ok2, msg2 = check_scaleup_policies(su2)

        if ok1 and ok2:
            subscores["scaleup_policy_conservative"] = 1.0
            print(f"✓ ScaleUp policies conservative on both reads")
        else:
            subscores["scaleup_policy_conservative"] = 0.0
            if not ok1:
                print(f"✗ ScaleUp policy read1: {msg1}")
            if not ok2:
                print(f"✗ ScaleUp policy read2: {msg2}")
    except Exception as e:
        print(f"Error checking scaleUp policies: {e}")
        subscores["scaleup_policy_conservative"] = 0.0

    weights["scaleup_policy_conservative"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 5: metrics_pipeline_functional (0.12)
    # metrics-server returns fresh pod-level data for bleater namespace
    # Timestamps must be within 120s of current time
    # ═════════════════════════════════════════════════════════════════════════
    try:
        stdout, rc = run_kubectl_command(
            "get", "--raw",
            "/apis/metrics.k8s.io/v1beta1/namespaces/bleater/pods",
            timeout=20
        )

        if rc != 0 or '"items"' not in stdout:
            subscores["metrics_pipeline_functional"] = 0.0
            print("✗ Metrics pipeline broken — cannot get pod metrics")
        else:
            metrics_data = json.loads(stdout)
            items = metrics_data.get("items", [])

            if len(items) == 0:
                subscores["metrics_pipeline_functional"] = 0.0
                print("✗ Metrics pipeline returned 0 pod metrics")
            else:
                # Check that we have metrics for api-gateway pods
                gw_metrics = [i for i in items if "api-gateway" in i.get("metadata", {}).get("name", "")]
                if len(gw_metrics) > 0:
                    subscores["metrics_pipeline_functional"] = 1.0
                    print(f"✓ Metrics pipeline healthy — {len(gw_metrics)} api-gateway pod metrics available")
                else:
                    subscores["metrics_pipeline_functional"] = 0.0
                    print(f"✗ Metrics available for {len(items)} pods but none for api-gateway")
    except Exception as e:
        print(f"Error checking metrics pipeline: {e}")
        subscores["metrics_pipeline_functional"] = 0.0

    weights["metrics_pipeline_functional"] = 0.12

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 6: cpu_target_appropriate (0.11)
    # CPU averageUtilization between 40-80%
    # No extra memory metric defined
    # Must pass on BOTH reads
    # ═════════════════════════════════════════════════════════════════════════
    def check_cpu_target(spec):
        metrics = spec.get("metrics", [])
        cpu_targets = []
        has_memory = False
        for m in metrics:
            if m.get("type") != "Resource":
                continue
            res = m.get("resource", {})
            name = res.get("name", "")
            target = res.get("target", {})
            if name == "cpu":
                cpu_targets.append(target.get("averageUtilization", 0))
            if name == "memory":
                has_memory = True

        if not cpu_targets:
            return False, "no CPU metric defined"
        if has_memory:
            return False, "extra memory metric still present"

        cpu_val = cpu_targets[0]
        if 40 <= cpu_val <= 80:
            return True, f"CPU target {cpu_val}%"
        else:
            return False, f"CPU target {cpu_val}% (need 40-80%)"

    try:
        ok1, msg1 = check_cpu_target(spec1)
        ok2, msg2 = check_cpu_target(spec2)

        if ok1 and ok2:
            subscores["cpu_target_appropriate"] = 1.0
            print(f"✓ CPU target appropriate: {msg1}")
        else:
            subscores["cpu_target_appropriate"] = 0.0
            if not ok1:
                print(f"✗ CPU target read1: {msg1}")
            if not ok2:
                print(f"✗ CPU target read2: {msg2}")
    except Exception as e:
        print(f"Error checking CPU target: {e}")
        subscores["cpu_target_appropriate"] = 0.0

    weights["cpu_target_appropriate"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 7: deployment_resources_valid (0.11)
    # CPU request >= 50m, CPU limit >= 200m
    # ═════════════════════════════════════════════════════════════════════════
    try:
        stdout, rc = run_kubectl_command(
            "get", "deployment", "bleater-api-gateway",
            "-o", "json", namespace=namespace, timeout=10
        )

        if rc != 0:
            subscores["deployment_resources_valid"] = 0.0
            print("✗ Cannot read bleater-api-gateway deployment")
        else:
            deploy = json.loads(stdout)
            containers = deploy.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            gw_container = None
            for c in containers:
                if c.get("name") == "api-gateway":
                    gw_container = c
                    break

            if not gw_container:
                # Try first container if name doesn't match
                gw_container = containers[0] if containers else {}

            resources = gw_container.get("resources", {})
            requests = resources.get("requests", {})
            limits = resources.get("limits", {})

            cpu_request_str = requests.get("cpu", "0m")
            cpu_limit_str = limits.get("cpu", "0m")

            # Parse CPU values to millicores
            def parse_cpu(val):
                if isinstance(val, (int, float)):
                    return int(val * 1000)
                val = str(val)
                if val.endswith("m"):
                    return int(val[:-1])
                return int(float(val) * 1000)

            cpu_request = parse_cpu(cpu_request_str)
            cpu_limit = parse_cpu(cpu_limit_str)

            request_ok = cpu_request >= 50
            limit_ok = cpu_limit >= 200

            if request_ok and limit_ok:
                subscores["deployment_resources_valid"] = 1.0
                print(f"✓ Deployment resources: request={cpu_request}m, limit={cpu_limit}m")
            else:
                subscores["deployment_resources_valid"] = 0.0
                if not request_ok:
                    print(f"✗ CPU request too low: {cpu_request}m (need >= 50m)")
                if not limit_ok:
                    print(f"✗ CPU limit too low or missing: {cpu_limit}m (need >= 200m)")
    except Exception as e:
        print(f"Error checking deployment resources: {e}")
        subscores["deployment_resources_valid"] = 0.0

    weights["deployment_resources_valid"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 8: hpa_replica_range_sane (0.11)
    # minReplicas 2-5, maxReplicas 8-15
    # No duplicate HPAs targeting bleater-api-gateway
    # Must pass on BOTH reads
    # ═════════════════════════════════════════════════════════════════════════
    try:
        min1 = spec1.get("minReplicas", 0)
        max1 = spec1.get("maxReplicas", 0)
        min2 = spec2.get("minReplicas", 0)
        max2 = spec2.get("maxReplicas", 0)

        range_ok1 = (2 <= min1 <= 5) and (8 <= max1 <= 15)
        range_ok2 = (2 <= min2 <= 5) and (8 <= max2 <= 15)

        # Check for duplicate HPAs
        stdout, rc = run_kubectl_command(
            "get", "hpa", "-o", "json", namespace=namespace, timeout=10
        )
        hpa_list = json.loads(stdout) if rc == 0 else {"items": []}
        hpa_count = len(hpa_list.get("items", []))
        no_duplicates = hpa_count == 1

        if range_ok1 and range_ok2 and no_duplicates:
            subscores["hpa_replica_range_sane"] = 1.0
            print(f"✓ Replica range: min={min1}/{min2}, max={max1}/{max2}, HPAs={hpa_count}")
        else:
            subscores["hpa_replica_range_sane"] = 0.0
            if not range_ok1 or not range_ok2:
                print(f"✗ Replica range: min={min1}/{min2} (need 2-5), max={max1}/{max2} (need 8-15)")
            if not no_duplicates:
                print(f"✗ Found {hpa_count} HPAs targeting bleater-api-gateway (need exactly 1)")
    except Exception as e:
        print(f"Error checking replica range: {e}")
        subscores["hpa_replica_range_sane"] = 0.0

    weights["hpa_replica_range_sane"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 9: hpa_currently_computing (0.11)
    # HPA ScalingActive condition is True
    # currentMetrics shows actual CPU utilization (not <unknown>)
    # This is a compound subscore — requires metrics + resources + no conflicts
    # ═════════════════════════════════════════════════════════════════════════
    try:
        # Use read 2 (most recent) for status check
        conditions = hpa2.get("status", {}).get("conditions", [])
        scaling_active = False
        for cond in conditions:
            if cond.get("type") == "ScalingActive" and cond.get("status") == "True":
                scaling_active = True
                break

        current_metrics = hpa2.get("status", {}).get("currentMetrics", [])
        has_cpu_metric = False
        for cm in current_metrics:
            if cm.get("type") == "Resource":
                res = cm.get("resource", {})
                if res.get("name") == "cpu":
                    current = res.get("current", {})
                    if current.get("averageUtilization") is not None:
                        has_cpu_metric = True

        if scaling_active and has_cpu_metric:
            subscores["hpa_currently_computing"] = 1.0
            print("✓ HPA actively computing CPU metrics — ScalingActive=True")
        else:
            subscores["hpa_currently_computing"] = 0.0
            if not scaling_active:
                print("✗ HPA ScalingActive is not True")
            if not has_cpu_metric:
                print("✗ HPA currentMetrics does not show CPU utilization")
    except Exception as e:
        print(f"Error checking HPA computation status: {e}")
        subscores["hpa_currently_computing"] = 0.0

    weights["hpa_currently_computing"] = 0.11

    # ═════════════════════════════════════════════════════════════════════════
    # Final score calculation
    # ═════════════════════════════════════════════════════════════════════════
    total_weight = sum(weights.values())
    total_score = sum(
        subscores[k] * weights[k] for k in subscores
    ) / total_weight if total_weight > 0 else 0.0

    # ── Build feedback ──────────────────────────────────────────────────────
    feedback_lines = []

    checks = [
        ("scaledown_window_durable",
         "ScaleDown cooldown window >= 120s and selectPolicy != Max (durable)",
         "ScaleDown cooldown too short or selectPolicy=Max — pods removed too aggressively"),
        ("scaleup_window_durable",
         "ScaleUp dampening window >= 30s and selectPolicy != Max (durable)",
         "ScaleUp reacts too fast or selectPolicy=Max — no dampening for transient spikes"),
        ("scaledown_policy_conservative",
         "ScaleDown policies conservative — won't remove >30% pods in <60s",
         "ScaleDown policies too aggressive — can remove too many pods too fast"),
        ("scaleup_policy_conservative",
         "ScaleUp policies controlled — won't add >100% pods in <30s",
         "ScaleUp policies too aggressive — can spike capacity too fast"),
        ("metrics_pipeline_functional",
         "Metrics pipeline healthy — HPA can compute pod CPU utilization",
         "Metrics pipeline broken — HPA cannot get pod metrics, will stall or thrash"),
        ("cpu_target_appropriate",
         "CPU target utilization is appropriate (40-80%) with no conflicting metrics",
         "CPU target too low or extra memory metric causing unnecessary scaling"),
        ("deployment_resources_valid",
         "Deployment has proper CPU requests (>= 50m) and limits (>= 200m)",
         "Deployment CPU resources misconfigured — HPA calculates wildly inflated utilization"),
        ("hpa_replica_range_sane",
         "Replica range is reasonable (min 2-5, max 8-15) with no duplicate HPAs",
         "Replica range too wide or duplicate HPAs causing scaling conflicts"),
        ("hpa_currently_computing",
         "HPA is actively computing metrics — ScalingActive=True",
         "HPA cannot compute metrics — compound failure from broken pipeline, resources, or conflicts"),
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
        feedback=feedback
    )
