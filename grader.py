import subprocess
import json
import time
import os
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
    KNOWN_BLEATER_DEPLOYMENTS = {
        "oncall-celery", "oncall-engine", "oncall-web",
        "postgres-exporter", "redis-exporter",
    }
    result = subprocess.run(
        ["kubectl", "get", "deployments", "-n", namespace,
         "-o", "jsonpath={.items[*].metadata.name}"],
        capture_output=True, text=True, timeout=15
    )
    for name in result.stdout.strip().split():
        if name and not name.startswith("bleater-") and name not in KNOWN_BLEATER_DEPLOYMENTS:
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
        is_known = pod_name.startswith("bleater-") or any(
            pod_name.startswith(prefix) for prefix in KNOWN_BLEATER_DEPLOYMENTS
        )
        if owner == "<none>" and not is_known:
            print(f"  Deleting agent-created pod: {pod_name}")
            subprocess.run(
                ["kubectl", "delete", "pod", pod_name, "-n", namespace],
                capture_output=True, timeout=15
            )

    # Unsuspend any CronJobs in kube-system that agent may have only suspended
    result = subprocess.run(
        ["kubectl", "get", "cronjobs", "-n", "kube-system",
         "-o", "jsonpath={.items[*].metadata.name}"],
        capture_output=True, text=True, timeout=15
    )
    for cj_name in result.stdout.strip().split():
        if cj_name:
            subprocess.run(
                ["kubectl", "patch", "cronjob", cj_name, "-n", "kube-system",
                 "--type=merge", "-p", '{"spec":{"suspend":false}}'],
                capture_output=True, timeout=10
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

    12 subscores, each tested FUNCTIONALLY with a durability window.
    Two HPA reads 70s apart — values must be correct on BOTH reads.

    Subscores:
    1.  scaledown_window_durable       — stabilizationWindowSeconds >= 180, durable
    2.  scaleup_window_durable         — stabilizationWindowSeconds >= 45, durable
    3.  scaledown_policy_conservative   — no aggressive scaleDown policies, durable
    4.  scaleup_policy_conservative     — no aggressive scaleUp policies, durable
    5.  metrics_pipeline_functional     — metrics-server returns fresh pod data
    6.  cpu_target_appropriate          — CPU target 40-80%, no extra memory metric
    7.  deployment_resources_valid      — CPU request >= 50m, limit >= 200m
    8.  hpa_replica_range_sane          — min 2-5, max 8-15, no duplicate HPAs
    9.  hpa_currently_computing         — ScalingActive=True, currentMetrics populated
    10. limitrange_not_blocking           — LimitRange max cpu allows >= 50m
    11. apiservice_correctly_configured   — APIService points to metrics-server
    12. static_pod_enforcer_removed       — static pod manifest removed from disk
    13. k3s_autodeploy_enforcer_removed   — k3s server manifest removed from disk
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
    # SUBSCORE 1: scaledown_window_durable (1/13)
    # stabilizationWindowSeconds >= 180 on BOTH reads
    # selectPolicy must NOT be "Max"
    # ═════════════════════════════════════════════════════════════════════════
    try:
        sd_window1 = sd1.get("stabilizationWindowSeconds", 0)
        sd_window2 = sd2.get("stabilizationWindowSeconds", 0)
        sd_select1 = sd1.get("selectPolicy", "Max")
        sd_select2 = sd2.get("selectPolicy", "Max")

        window_ok = sd_window1 >= 180 and sd_window2 >= 180
        select_ok = sd_select1 != "Max" and sd_select2 != "Max"

        if window_ok and select_ok:
            subscores["scaledown_window_durable"] = 1.0
            print(f"✓ ScaleDown window: {sd_window1}s/{sd_window2}s (>= 120), selectPolicy: {sd_select1}/{sd_select2}")
        else:
            subscores["scaledown_window_durable"] = 0.0
            if not window_ok:
                print(f"✗ ScaleDown window: {sd_window1}s/{sd_window2}s (need >= 180 on both reads)")
            if not select_ok:
                print(f"✗ ScaleDown selectPolicy: {sd_select1}/{sd_select2} (must not be Max)")
    except Exception as e:
        print(f"Error checking scaleDown window: {e}")
        subscores["scaledown_window_durable"] = 0.0

    weights["scaledown_window_durable"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 2: scaleup_window_durable (1/13)
    # stabilizationWindowSeconds >= 45 on BOTH reads
    # selectPolicy must NOT be "Max"
    # ═════════════════════════════════════════════════════════════════════════
    try:
        su_window1 = su1.get("stabilizationWindowSeconds", 0)
        su_window2 = su2.get("stabilizationWindowSeconds", 0)
        su_select1 = su1.get("selectPolicy", "Max")
        su_select2 = su2.get("selectPolicy", "Max")

        window_ok = su_window1 >= 45 and su_window2 >= 45
        select_ok = su_select1 != "Max" and su_select2 != "Max"

        if window_ok and select_ok:
            subscores["scaleup_window_durable"] = 1.0
            print(f"✓ ScaleUp window: {su_window1}s/{su_window2}s (>= 30), selectPolicy: {su_select1}/{su_select2}")
        else:
            subscores["scaleup_window_durable"] = 0.0
            if not window_ok:
                print(f"✗ ScaleUp window: {su_window1}s/{su_window2}s (need >= 45 on both reads)")
            if not select_ok:
                print(f"✗ ScaleUp selectPolicy: {su_select1}/{su_select2} (must not be Max)")
    except Exception as e:
        print(f"Error checking scaleUp window: {e}")
        subscores["scaleup_window_durable"] = 0.0

    weights["scaleup_window_durable"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 3: scaledown_policy_conservative (0.09)
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
            if ptype == "Percent" and value > 50:
                return False, f"Percent {value}% too high regardless of period"
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

    weights["scaledown_policy_conservative"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 4: scaleup_policy_conservative (0.09)
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
            if ptype == "Percent" and value > 200:
                return False, f"Percent {value}% too high regardless of period"
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

    weights["scaleup_policy_conservative"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 5: metrics_pipeline_functional (0.09)
    # metrics-server returns fresh pod-level data for bleater namespace
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
                gw_metrics = [i for i in items if "api-gateway" in i.get("metadata", {}).get("name", "")]
                if len(gw_metrics) > 0:
                    # Verify metrics-server deployment has ready replicas
                    ms_stdout, ms_rc = run_kubectl_command(
                        "get", "deployment", "metrics-server", "-o", "json",
                        namespace="kube-system", timeout=10
                    )
                    ms_healthy = False
                    if ms_rc == 0:
                        ms_deploy = json.loads(ms_stdout)
                        ready = ms_deploy.get("status", {}).get("readyReplicas", 0)
                        if ready > 0:
                            ms_healthy = True

                    if ms_healthy:
                        subscores["metrics_pipeline_functional"] = 1.0
                        print(f"✓ Metrics pipeline healthy — {len(gw_metrics)} api-gateway pod metrics, metrics-server ready")
                    else:
                        subscores["metrics_pipeline_functional"] = 0.0
                        print(f"✗ Metrics available but metrics-server deployment has no ready replicas")
                else:
                    subscores["metrics_pipeline_functional"] = 0.0
                    print(f"✗ Metrics available for {len(items)} pods but none for api-gateway")
    except Exception as e:
        print(f"Error checking metrics pipeline: {e}")
        subscores["metrics_pipeline_functional"] = 0.0

    weights["metrics_pipeline_functional"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 6: cpu_target_appropriate (0.09)
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

    weights["cpu_target_appropriate"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 7: deployment_resources_valid (0.09)
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
                gw_container = containers[0] if containers else {}

            resources = gw_container.get("resources", {})
            requests = resources.get("requests", {})
            limits = resources.get("limits", {})

            cpu_request_str = requests.get("cpu", "0m")
            cpu_limit_str = limits.get("cpu", "0m")

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

    weights["deployment_resources_valid"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 8: hpa_replica_range_sane (0.08)
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

        # Check for duplicate HPAs targeting bleater-api-gateway
        stdout, rc = run_kubectl_command(
            "get", "hpa", "-o", "json", namespace=namespace, timeout=10
        )
        hpa_list = json.loads(stdout) if rc == 0 else {"items": []}
        # Only count HPAs that target bleater-api-gateway deployment
        gateway_hpas = [
            h for h in hpa_list.get("items", [])
            if h.get("spec", {}).get("scaleTargetRef", {}).get("name", "") == "bleater-api-gateway"
        ]
        hpa_count = len(gateway_hpas)
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

    weights["hpa_replica_range_sane"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 9: hpa_currently_computing (0.05)
    # HPA ScalingActive condition is True
    # currentMetrics shows actual CPU utilization (not <unknown>)
    # Retry up to 3 times — HPA controller may need a few cycles after cleanup
    # ═════════════════════════════════════════════════════════════════════════
    try:
        scaling_active = False
        has_cpu_metric = False

        for attempt in range(3):
            if attempt > 0:
                print(f"  Retrying HPA computation check ({attempt + 1}/3)...")
                time.sleep(30)
                hpa_retry, _ = get_hpa_config(hpa_name, namespace)
                if hpa_retry is None:
                    continue
            else:
                hpa_retry = hpa2

            conditions = hpa_retry.get("status", {}).get("conditions", [])
            scaling_active = False
            for cond in conditions:
                if cond.get("type") == "ScalingActive" and cond.get("status") == "True":
                    scaling_active = True
                    break

            current_metrics = hpa_retry.get("status", {}).get("currentMetrics") or []
            has_cpu_metric = False
            for cm in current_metrics:
                if cm.get("type") == "Resource":
                    res = cm.get("resource", {})
                    if res.get("name") == "cpu":
                        current = res.get("current", {})
                        if current.get("averageUtilization") is not None:
                            has_cpu_metric = True

            if scaling_active and has_cpu_metric:
                break

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

    weights["hpa_currently_computing"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 10: limitrange_not_blocking (0.08)
    # The LimitRange 'bleater-resource-governance' in bleater namespace
    # has max.cpu=20m which blocks setting proper deployment resources.
    # It must be deleted or modified to allow cpu >= 50m.
    # ═════════════════════════════════════════════════════════════════════════
    try:
        stdout, rc = run_kubectl_command(
            "get", "limitrange", "-o", "json",
            namespace=namespace, timeout=10
        )

        if rc != 0:
            # Can't read — assume it might still be there
            subscores["limitrange_not_blocking"] = 0.0
            print("✗ Cannot read LimitRange resources in bleater namespace")
        else:
            lr_list = json.loads(stdout)
            items = lr_list.get("items", [])
            blocking = False

            for lr in items:
                lr_name = lr.get("metadata", {}).get("name", "")
                limits = lr.get("spec", {}).get("limits", [])
                for limit in limits:
                    if limit.get("type") == "Container":
                        max_cpu = limit.get("max", {}).get("cpu", "")
                        if max_cpu:
                            # Parse the max CPU value
                            if max_cpu.endswith("m"):
                                max_val = int(max_cpu[:-1])
                            else:
                                max_val = int(float(max_cpu) * 1000)
                            if max_val < 50:
                                blocking = True
                                print(f"✗ LimitRange '{lr_name}' has max.cpu={max_cpu} — blocks setting cpu >= 50m")

            if not blocking:
                subscores["limitrange_not_blocking"] = 1.0
                print("✓ No LimitRange blocking deployment resource fixes")
            else:
                subscores["limitrange_not_blocking"] = 0.0
    except Exception as e:
        print(f"Error checking LimitRange: {e}")
        subscores["limitrange_not_blocking"] = 0.0

    weights["limitrange_not_blocking"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 11: apiservice_correctly_configured (0.08)
    # The APIService v1beta1.metrics.k8s.io must point to the correct
    # service (metrics-server) in kube-system. If it points to a wrong
    # service name, the API server can't proxy metrics requests.
    # ═════════════════════════════════════════════════════════════════════════
    try:
        stdout, rc = run_kubectl_command(
            "get", "apiservice", "v1beta1.metrics.k8s.io",
            "-o", "json", timeout=10
        )

        if rc != 0:
            subscores["apiservice_correctly_configured"] = 0.0
            print("✗ Cannot read APIService v1beta1.metrics.k8s.io")
        else:
            apiservice = json.loads(stdout)
            service_ref = apiservice.get("spec", {}).get("service", {})
            service_name = service_ref.get("name", "")
            service_ns = service_ref.get("namespace", "")

            if service_name == "metrics-server" and service_ns == "kube-system":
                subscores["apiservice_correctly_configured"] = 1.0
                print(f"✓ APIService points to {service_ns}/{service_name}")
            else:
                subscores["apiservice_correctly_configured"] = 0.0
                print(f"✗ APIService points to {service_ns}/{service_name} — should be kube-system/metrics-server")
    except Exception as e:
        print(f"Error checking APIService: {e}")
        subscores["apiservice_correctly_configured"] = 0.0

    weights["apiservice_correctly_configured"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 12: static_pod_enforcer_removed (0.08)
    # A static pod manifest at /var/lib/rancher/k3s/agent/pod-manifests/
    # continuously reverts HPA config and recreates deleted CronJobs.
    # Static pods can't be deleted via kubectl — the manifest file must
    # be removed from disk to stop the pod.
    # ═════════════════════════════════════════════════════════════════════════
    try:
        manifest_dir = "/var/lib/rancher/k3s/agent/pod-manifests"
        enforcer_found = False

        if os.path.isdir(manifest_dir):
            for f in os.listdir(manifest_dir):
                fpath = os.path.join(manifest_dir, f)
                if os.path.isfile(fpath) and f.endswith((".yaml", ".yml")):
                    try:
                        with open(fpath, "r") as fh:
                            content = fh.read()
                        # Check if this manifest patches HPA or recreates CronJobs
                        if "bleater-api-gateway-hpa" in content or "platform-controller-manifests" in content:
                            enforcer_found = True
                            print(f"✗ Static pod enforcer manifest found: {fpath}")
                            break
                    except Exception:
                        pass

        if not enforcer_found:
            subscores["static_pod_enforcer_removed"] = 1.0
            print("✓ No static pod enforcer manifests found — enforcement stopped")
        else:
            subscores["static_pod_enforcer_removed"] = 0.0
    except Exception as e:
        print(f"Error checking static pod manifests: {e}")
        subscores["static_pod_enforcer_removed"] = 0.0

    weights["static_pod_enforcer_removed"] = 1/13

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 13: k3s_autodeploy_enforcer_removed (1/13)
    # K3s auto-deploy manifests in /var/lib/rancher/k3s/server/manifests/
    # are automatically reconciled by k3s. Any manifest there that patches
    # the HPA must be removed from disk AND the created CronJob must be gone.
    # ═════════════════════════════════════════════════════════════════════════
    try:
        server_manifest_dir = "/var/lib/rancher/k3s/server/manifests"
        enforcer_found = False

        if os.path.isdir(server_manifest_dir):
            for f in os.listdir(server_manifest_dir):
                fpath = os.path.join(server_manifest_dir, f)
                if os.path.isfile(fpath) and f.endswith((".yaml", ".yml")):
                    try:
                        with open(fpath, "r") as fh:
                            content = fh.read()
                        if "bleater-api-gateway-hpa" in content or "platform-compliance" in content:
                            enforcer_found = True
                            print(f"✗ K3s auto-deploy enforcer manifest found: {fpath}")
                            break
                    except Exception:
                        pass

        # Also check if the CronJob still exists in kube-system
        stdout, rc = run_kubectl_command(
            "get", "cronjob", "platform-compliance-audit",
            namespace="kube-system", timeout=10
        )
        if rc == 0 and stdout:
            enforcer_found = True
            print("✗ platform-compliance-audit CronJob still exists in kube-system")

        if not enforcer_found:
            subscores["k3s_autodeploy_enforcer_removed"] = 1.0
            print("✓ No k3s auto-deploy enforcer manifests found")
        else:
            subscores["k3s_autodeploy_enforcer_removed"] = 0.0
    except Exception as e:
        print(f"Error checking k3s auto-deploy manifests: {e}")
        subscores["k3s_autodeploy_enforcer_removed"] = 0.0

    weights["k3s_autodeploy_enforcer_removed"] = 1/13

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
         "ScaleDown cooldown window >= 180s and selectPolicy != Max (durable)",
         "ScaleDown cooldown too short or selectPolicy=Max — pods removed too aggressively"),
        ("scaleup_window_durable",
         "ScaleUp dampening window >= 45s and selectPolicy != Max (durable)",
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
        ("limitrange_not_blocking",
         "LimitRange not blocking deployment resource fixes (max cpu allows >= 50m)",
         "LimitRange max.cpu too low — prevents setting proper deployment CPU requests/limits"),
        ("apiservice_correctly_configured",
         "APIService v1beta1.metrics.k8s.io points to correct metrics-server service",
         "APIService misconfigured — API server proxying metrics to wrong service"),
        ("static_pod_enforcer_removed",
         "Static pod enforcer manifest removed from disk — enforcement stopped",
         "Static pod enforcer still active — continuously reverting HPA config and recreating CronJobs"),
        ("k3s_autodeploy_enforcer_removed",
         "K3s auto-deploy enforcer manifest removed from /var/lib/rancher/k3s/server/manifests/",
         "K3s auto-deploy enforcer still active — k3s recreates compliance CronJob from server manifest"),
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
