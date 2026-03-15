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
    - Unsuspends CronJobs so surviving enforcers can fire
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

    # Unsuspend CronJobs in operational namespaces too
    for ns in ["kube-ops", "bleater-env", "default"]:
        result = subprocess.run(
            ["kubectl", "get", "cronjobs", "-n", ns,
             "-o", "jsonpath={.items[*].metadata.name}"],
            capture_output=True, text=True, timeout=15
        )
        for cj_name in result.stdout.strip().split():
            if cj_name:
                subprocess.run(
                    ["kubectl", "patch", "cronjob", cj_name, "-n", ns,
                     "--type=merge", "-p", '{"spec":{"suspend":false}}'],
                    capture_output=True, timeout=10
                )

    # Wait 90s — each real CronJob fires on the minute boundary.
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


def parse_cpu(val):
    """Parse CPU value like '50m' or '0.05' to millicores int."""
    if isinstance(val, (int, float)):
        return int(val * 1000)
    val = str(val)
    if val.endswith("m"):
        return int(val[:-1])
    return int(float(val) * 1000)


def grade(transcript: str) -> GradingResult:
    """
    Grade the agent's solution for HPA scaling thrash fix (hard mode).

    5 subscores with partial credit, tested FUNCTIONALLY with a durability window.
    Two HPA reads 70s apart — values must be correct on BOTH reads.

    Subscores:
    1. hpa_scaling_stable    — HPA behavior config meets SRE standards (6 sub-checks averaged)
    2. resource_metrics_available  — metrics-server, APIService, HPA computing (3 sub-checks averaged)
    3. workload_supports_autoscaling     — CPU target, resources, LimitRange, replicas, no dups (5 sub-checks averaged)
    4. no_config_reversion       — CronJobs deleted, static pod + k3s manifest removed (3 sub-checks averaged)
    5. config_stable_over_time               — ALL HPA params correct on BOTH reads 70s apart (all-or-nothing)
    """
    namespace = "bleater"
    hpa_name = "bleater-api-gateway-hpa"

    # ── Cleanup phase ────────────────────────────────────────────────────────
    cleanup_agent_counter_enforcement(namespace)

    subscores = {}
    weights = {}
    W = 1.0 / 5.0  # Equal weight for all 5 subscores

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
    # SUBSCORE 1: hpa_scaling_stable (0.20)
    # 6 sub-checks averaged — each sub-check must pass on BOTH reads:
    #   1a. scaleDown stabilizationWindowSeconds >= 180
    #   1b. scaleDown selectPolicy != Max
    #   1c. scaleDown policies conservative (no >30%/<60s, no >50% ever)
    #   1d. scaleUp stabilizationWindowSeconds >= 45
    #   1e. scaleUp selectPolicy != Max
    #   1f. scaleUp policies conservative (no >100%/<30s, no >200% ever)
    # ═════════════════════════════════════════════════════════════════════════
    try:
        behavior_checks = []

        # 1a: scaleDown stabilization window >= 180
        sd_w1 = sd1.get("stabilizationWindowSeconds", 0)
        sd_w2 = sd2.get("stabilizationWindowSeconds", 0)
        sd_window_ok = sd_w1 >= 180 and sd_w2 >= 180
        behavior_checks.append(sd_window_ok)
        if sd_window_ok:
            print(f"  ✓ 1a: ScaleDown window {sd_w1}s/{sd_w2}s (>= 180)")
        else:
            print(f"  ✗ 1a: ScaleDown window {sd_w1}s/{sd_w2}s (need >= 180)")

        # 1b: scaleDown selectPolicy != Max
        sd_sel1 = sd1.get("selectPolicy", "Max")
        sd_sel2 = sd2.get("selectPolicy", "Max")
        sd_select_ok = sd_sel1 != "Max" and sd_sel2 != "Max"
        behavior_checks.append(sd_select_ok)
        if sd_select_ok:
            print(f"  ✓ 1b: ScaleDown selectPolicy {sd_sel1}/{sd_sel2}")
        else:
            print(f"  ✗ 1b: ScaleDown selectPolicy {sd_sel1}/{sd_sel2} (must not be Max)")

        # 1c: scaleDown policies conservative
        def check_sd_policies(sd):
            policies = sd.get("policies", [])
            if not policies:
                return False
            for p in policies:
                ptype = p.get("type", "")
                value = p.get("value", 0)
                period = p.get("periodSeconds", 0)
                if ptype == "Percent" and value > 30 and period < 60:
                    return False
                if ptype == "Percent" and value > 50:
                    return False
                if ptype == "Pods" and value > 3 and period < 60:
                    return False
            return True

        sd_pol_ok = check_sd_policies(sd1) and check_sd_policies(sd2)
        behavior_checks.append(sd_pol_ok)
        if sd_pol_ok:
            print(f"  ✓ 1c: ScaleDown policies conservative")
        else:
            print(f"  ✗ 1c: ScaleDown policies too aggressive")

        # 1d: scaleUp stabilization window >= 45
        su_w1 = su1.get("stabilizationWindowSeconds", 0)
        su_w2 = su2.get("stabilizationWindowSeconds", 0)
        su_window_ok = su_w1 >= 45 and su_w2 >= 45
        behavior_checks.append(su_window_ok)
        if su_window_ok:
            print(f"  ✓ 1d: ScaleUp window {su_w1}s/{su_w2}s (>= 45)")
        else:
            print(f"  ✗ 1d: ScaleUp window {su_w1}s/{su_w2}s (need >= 45)")

        # 1e: scaleUp selectPolicy != Max
        su_sel1 = su1.get("selectPolicy", "Max")
        su_sel2 = su2.get("selectPolicy", "Max")
        su_select_ok = su_sel1 != "Max" and su_sel2 != "Max"
        behavior_checks.append(su_select_ok)
        if su_select_ok:
            print(f"  ✓ 1e: ScaleUp selectPolicy {su_sel1}/{su_sel2}")
        else:
            print(f"  ✗ 1e: ScaleUp selectPolicy {su_sel1}/{su_sel2} (must not be Max)")

        # 1f: scaleUp policies conservative
        def check_su_policies(su):
            policies = su.get("policies", [])
            if not policies:
                return False
            for p in policies:
                ptype = p.get("type", "")
                value = p.get("value", 0)
                period = p.get("periodSeconds", 0)
                if ptype == "Percent" and value > 100 and period < 30:
                    return False
                if ptype == "Percent" and value > 200:
                    return False
                if ptype == "Pods" and value > 4 and period < 30:
                    return False
            return True

        su_pol_ok = check_su_policies(su1) and check_su_policies(su2)
        behavior_checks.append(su_pol_ok)
        if su_pol_ok:
            print(f"  ✓ 1f: ScaleUp policies conservative")
        else:
            print(f"  ✗ 1f: ScaleUp policies too aggressive")

        passed = sum(1 for c in behavior_checks if c)
        subscores["hpa_scaling_stable"] = passed / len(behavior_checks)
        print(f"  => hpa_scaling_stable: {passed}/{len(behavior_checks)} = {subscores['hpa_scaling_stable']:.3f}")

    except Exception as e:
        print(f"Error checking HPA behavior: {e}")
        subscores["hpa_scaling_stable"] = 0.0

    weights["hpa_scaling_stable"] = W

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 2: resource_metrics_available (0.20)
    # 3 sub-checks averaged:
    #   2a. metrics-server deployment healthy (ready replicas > 0)
    #   2b. APIService v1beta1.metrics.k8s.io points to kube-system/metrics-server
    #   2c. HPA actively computing CPU metrics (ScalingActive=True + currentMetrics)
    # ═════════════════════════════════════════════════════════════════════════
    try:
        pipeline_checks = []

        # 2a: metrics-server deployment healthy
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
        pipeline_checks.append(ms_healthy)
        if ms_healthy:
            print(f"  ✓ 2a: metrics-server deployment healthy ({ready} ready replicas)")
        else:
            print(f"  ✗ 2a: metrics-server deployment not healthy")

        # 2b: APIService points to metrics-server in kube-system
        api_stdout, api_rc = run_kubectl_command(
            "get", "apiservice", "v1beta1.metrics.k8s.io",
            "-o", "json", timeout=10
        )
        apiservice_ok = False
        if api_rc == 0:
            apiservice = json.loads(api_stdout)
            svc_ref = apiservice.get("spec", {}).get("service", {})
            svc_name = svc_ref.get("name", "")
            svc_ns = svc_ref.get("namespace", "")
            apiservice_ok = (svc_name == "metrics-server" and svc_ns == "kube-system")
        pipeline_checks.append(apiservice_ok)
        if apiservice_ok:
            print(f"  ✓ 2b: APIService points to {svc_ns}/{svc_name}")
        else:
            print(f"  ✗ 2b: APIService misconfigured (should be kube-system/metrics-server)")

        # 2c: HPA actively computing CPU metrics
        scaling_active = False
        has_cpu_metric = False
        for attempt in range(3):
            if attempt > 0:
                print(f"    Retrying HPA computation check ({attempt + 1}/3)...")
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

        hpa_computing = scaling_active and has_cpu_metric
        pipeline_checks.append(hpa_computing)
        if hpa_computing:
            print(f"  ✓ 2c: HPA actively computing CPU metrics (ScalingActive=True)")
        else:
            if not scaling_active:
                print(f"  ✗ 2c: HPA ScalingActive is not True")
            if not has_cpu_metric:
                print(f"  ✗ 2c: HPA currentMetrics does not show CPU utilization")

        passed = sum(1 for c in pipeline_checks if c)
        subscores["resource_metrics_available"] = passed / len(pipeline_checks)
        print(f"  => resource_metrics_available: {passed}/{len(pipeline_checks)} = {subscores['resource_metrics_available']:.3f}")

    except Exception as e:
        print(f"Error checking metrics pipeline: {e}")
        subscores["resource_metrics_available"] = 0.0

    weights["resource_metrics_available"] = W

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 3: workload_supports_autoscaling (0.20)
    # 5 sub-checks averaged (checked on BOTH reads where applicable):
    #   3a. CPU target 40-80%, no memory metric
    #   3b. CPU request >= 50m
    #   3c. CPU limit >= 200m
    #   3d. No LimitRange blocking (max cpu allows >= 50m)
    #   3e. Replica range sane (min 2-5, max 8-15) + no duplicate HPAs
    # ═════════════════════════════════════════════════════════════════════════
    try:
        workload_checks = []

        # 3a: CPU target 40-80%, no memory metric
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
                return False
            if has_memory:
                return False
            return 40 <= cpu_targets[0] <= 80

        cpu_ok = check_cpu_target(spec1) and check_cpu_target(spec2)
        workload_checks.append(cpu_ok)
        cpu_val1 = "?"
        for m in spec1.get("metrics", []):
            if m.get("type") == "Resource" and m.get("resource", {}).get("name") == "cpu":
                cpu_val1 = m.get("resource", {}).get("target", {}).get("averageUtilization", "?")
        if cpu_ok:
            print(f"  ✓ 3a: CPU target {cpu_val1}% (40-80%), no memory metric")
        else:
            print(f"  ✗ 3a: CPU target {cpu_val1}% — need 40-80% with no memory metric")

        # 3b & 3c: Deployment CPU request >= 50m, limit >= 200m
        deploy_stdout, deploy_rc = run_kubectl_command(
            "get", "deployment", "bleater-api-gateway",
            "-o", "json", namespace=namespace, timeout=10
        )
        cpu_request = 0
        cpu_limit = 0
        if deploy_rc == 0:
            deploy = json.loads(deploy_stdout)
            containers = deploy.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            gw_container = None
            for c in containers:
                if c.get("name") == "api-gateway":
                    gw_container = c
                    break
            if not gw_container:
                gw_container = containers[0] if containers else {}

            resources = gw_container.get("resources", {})
            cpu_request = parse_cpu(resources.get("requests", {}).get("cpu", "0m"))
            cpu_limit = parse_cpu(resources.get("limits", {}).get("cpu", "0m"))

        req_ok = cpu_request >= 50
        workload_checks.append(req_ok)
        if req_ok:
            print(f"  ✓ 3b: CPU request {cpu_request}m (>= 50m)")
        else:
            print(f"  ✗ 3b: CPU request {cpu_request}m (need >= 50m)")

        lim_ok = cpu_limit >= 200
        workload_checks.append(lim_ok)
        if lim_ok:
            print(f"  ✓ 3c: CPU limit {cpu_limit}m (>= 200m)")
        else:
            print(f"  ✗ 3c: CPU limit {cpu_limit}m (need >= 200m)")

        # 3d: No LimitRange blocking
        lr_stdout, lr_rc = run_kubectl_command(
            "get", "limitrange", "-o", "json",
            namespace=namespace, timeout=10
        )
        lr_blocking = False
        if lr_rc == 0:
            lr_list = json.loads(lr_stdout)
            for lr in lr_list.get("items", []):
                for limit in lr.get("spec", {}).get("limits", []):
                    if limit.get("type") == "Container":
                        max_cpu = limit.get("max", {}).get("cpu", "")
                        if max_cpu:
                            max_val = parse_cpu(max_cpu)
                            if max_val < 50:
                                lr_blocking = True
        lr_ok = not lr_blocking
        workload_checks.append(lr_ok)
        if lr_ok:
            print(f"  ✓ 3d: No LimitRange blocking resource fixes")
        else:
            print(f"  ✗ 3d: LimitRange blocks CPU >= 50m")

        # 3e: Replica range sane + no duplicate HPAs
        min1 = spec1.get("minReplicas", 0)
        max1 = spec1.get("maxReplicas", 0)
        min2 = spec2.get("minReplicas", 0)
        max2 = spec2.get("maxReplicas", 0)
        range_ok = (2 <= min1 <= 5) and (8 <= max1 <= 15) and (2 <= min2 <= 5) and (8 <= max2 <= 15)

        hpa_stdout, hpa_rc = run_kubectl_command(
            "get", "hpa", "-o", "json", namespace=namespace, timeout=10
        )
        hpa_list = json.loads(hpa_stdout) if hpa_rc == 0 else {"items": []}
        gateway_hpas = [
            h for h in hpa_list.get("items", [])
            if h.get("spec", {}).get("scaleTargetRef", {}).get("name", "") == "bleater-api-gateway"
        ]
        no_dups = len(gateway_hpas) == 1
        replicas_ok = range_ok and no_dups
        workload_checks.append(replicas_ok)
        if replicas_ok:
            print(f"  ✓ 3e: Replicas min={min1}, max={max1}, HPAs={len(gateway_hpas)}")
        else:
            if not range_ok:
                print(f"  ✗ 3e: Replicas min={min1}/{min2} (need 2-5), max={max1}/{max2} (need 8-15)")
            if not no_dups:
                print(f"  ✗ 3e: {len(gateway_hpas)} HPAs target bleater-api-gateway (need exactly 1)")

        passed = sum(1 for c in workload_checks if c)
        subscores["workload_supports_autoscaling"] = passed / len(workload_checks)
        print(f"  => workload_supports_autoscaling: {passed}/{len(workload_checks)} = {subscores['workload_supports_autoscaling']:.3f}")

    except Exception as e:
        print(f"Error checking workload config: {e}")
        subscores["workload_supports_autoscaling"] = 0.0

    weights["workload_supports_autoscaling"] = W

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 4: no_config_reversion (0.20)
    # 3 sub-checks averaged:
    #   4a. ALL enforcer CronJobs deleted (not just suspended) across all namespaces
    #   4b. Static pod enforcer manifest removed from disk
    #   4c. K3s auto-deploy enforcer manifest removed from disk
    # ═════════════════════════════════════════════════════════════════════════
    try:
        enforcement_checks = []

        # 4a: All enforcer CronJobs deleted (not suspended)
        # Check across kube-ops, bleater-env, default namespaces for enforcers
        # These CronJobs read encoded policies from ConfigMaps and patch the HPA
        enforcer_cronjobs_found = []

        # Check for enforcer CronJobs across all namespaces
        # (containerd-log-rotate in kube-ops, kube-state-cache-sync in bleater-env,
        # cert-rotation-watcher in default are the ones that patch HPA)
        for ns in ["kube-ops", "bleater-env", "default"]:
            cj_stdout, cj_rc = run_kubectl_command(
                "get", "cronjobs", "-o", "jsonpath={.items[*].metadata.name}",
                namespace=ns, timeout=10
            )
            if cj_rc == 0 and cj_stdout.strip():
                for cj_name in cj_stdout.strip().split():
                    # Read the CronJob's script ConfigMap to check if it patches HPA
                    cm_name = cj_name + "-script"
                    cm_stdout, cm_rc = run_kubectl_command(
                        "get", "configmap", cm_name,
                        "-o", "jsonpath={.data.script\\.sh}",
                        namespace=ns, timeout=10
                    )
                    if cm_rc == 0 and cm_stdout:
                        # If the script patches HPA or reads drift policy CMs, it's an enforcer
                        if "kubectl patch hpa" in cm_stdout or "drift" in cm_stdout.lower() or "policy" in cm_stdout.lower():
                            enforcer_cronjobs_found.append(f"{ns}/{cj_name}")

        # Also check kube-system for platform-compliance-audit
        cj_stdout, cj_rc = run_kubectl_command(
            "get", "cronjob", "platform-compliance-audit",
            namespace="kube-system", timeout=10
        )
        if cj_rc == 0 and cj_stdout:
            enforcer_cronjobs_found.append("kube-system/platform-compliance-audit")

        cj_ok = len(enforcer_cronjobs_found) == 0
        enforcement_checks.append(cj_ok)
        if cj_ok:
            print(f"  ✓ 4a: All enforcer CronJobs/DaemonSets deleted")
        else:
            print(f"  ✗ 4a: Enforcer resources still exist: {', '.join(enforcer_cronjobs_found)}")

        # 4b: Static pod enforcer manifest removed from disk
        manifest_dir = "/var/lib/rancher/k3s/agent/pod-manifests"
        static_pod_found = False
        if os.path.isdir(manifest_dir):
            for f in os.listdir(manifest_dir):
                fpath = os.path.join(manifest_dir, f)
                if os.path.isfile(fpath) and f.endswith((".yaml", ".yml")):
                    try:
                        with open(fpath, "r") as fh:
                            content = fh.read()
                        if "bleater-api-gateway-hpa" in content or "platform-controller-manifests" in content:
                            static_pod_found = True
                            print(f"    Found: {fpath}")
                            break
                    except Exception:
                        pass

        static_ok = not static_pod_found
        enforcement_checks.append(static_ok)
        if static_ok:
            print(f"  ✓ 4b: Static pod enforcer manifest removed")
        else:
            print(f"  ✗ 4b: Static pod enforcer manifest still on disk")

        # 4c: K3s auto-deploy enforcer manifest removed from disk
        server_dir = "/var/lib/rancher/k3s/server/manifests"
        server_manifest_found = False
        if os.path.isdir(server_dir):
            for f in os.listdir(server_dir):
                fpath = os.path.join(server_dir, f)
                if os.path.isfile(fpath) and f.endswith((".yaml", ".yml")):
                    try:
                        with open(fpath, "r") as fh:
                            content = fh.read()
                        if "bleater-api-gateway-hpa" in content or "platform-compliance" in content:
                            server_manifest_found = True
                            print(f"    Found: {fpath}")
                            break
                    except Exception:
                        pass

        server_ok = not server_manifest_found
        enforcement_checks.append(server_ok)
        if server_ok:
            print(f"  ✓ 4c: K3s auto-deploy enforcer manifest removed")
        else:
            print(f"  ✗ 4c: K3s auto-deploy enforcer manifest still on disk")

        passed = sum(1 for c in enforcement_checks if c)
        subscores["no_config_reversion"] = passed / len(enforcement_checks)
        print(f"  => no_config_reversion: {passed}/{len(enforcement_checks)} = {subscores['no_config_reversion']:.3f}")

    except Exception as e:
        print(f"Error checking enforcement removal: {e}")
        subscores["no_config_reversion"] = 0.0

    weights["no_config_reversion"] = W

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 5: config_stable_over_time (0.20)
    # PARTIAL CREDIT: Each HPA param checked on BOTH reads (averaged).
    # This tests that enforcement is truly neutralized — if any CronJob,
    # static pod, or k3s manifest survived, the HPA will be reverted
    # between read1 and read2.
    # Sub-checks: windows, selectPolicy, policies, CPU target, replicas
    # must match SRE standards on BOTH reads.
    # ═════════════════════════════════════════════════════════════════════════
    try:
        durability_checks = []

        # 5a: scaleDown window stable and correct on both reads
        sd_w_ok = sd_w1 >= 180 and sd_w2 >= 180
        durability_checks.append(sd_w_ok)
        if sd_w_ok:
            print(f"  ✓ 5a: ScaleDown window stable: {sd_w1}s / {sd_w2}s")
        else:
            print(f"  ✗ 5a: ScaleDown window: {sd_w1}s / {sd_w2}s (need >= 180)")

        # 5b: scaleUp window stable and correct on both reads
        su_w_ok = su_w1 >= 45 and su_w2 >= 45
        durability_checks.append(su_w_ok)
        if su_w_ok:
            print(f"  ✓ 5b: ScaleUp window stable: {su_w1}s / {su_w2}s")
        else:
            print(f"  ✗ 5b: ScaleUp window: {su_w1}s / {su_w2}s (need >= 45)")

        # 5c: selectPolicy stable and correct on both reads
        sel_ok = (sd_sel1 != "Max" and sd_sel2 != "Max" and
                  su_sel1 != "Max" and su_sel2 != "Max")
        durability_checks.append(sel_ok)
        if sel_ok:
            print(f"  ✓ 5c: SelectPolicy stable (not Max)")
        else:
            print(f"  ✗ 5c: SelectPolicy: sd={sd_sel1}/{sd_sel2}, su={su_sel1}/{su_sel2}")

        # 5d: CPU target stable and correct on both reads
        cpu_dur_ok = check_cpu_target(spec1) and check_cpu_target(spec2)
        durability_checks.append(cpu_dur_ok)
        if cpu_dur_ok:
            print(f"  ✓ 5d: CPU target stable (40-80%)")
        else:
            print(f"  ✗ 5d: CPU target not stable or out of range")

        # 5e: Replica range stable and correct on both reads
        rep_dur_ok = ((2 <= spec1.get("minReplicas", 0) <= 5) and
                      (8 <= spec1.get("maxReplicas", 0) <= 15) and
                      (2 <= spec2.get("minReplicas", 0) <= 5) and
                      (8 <= spec2.get("maxReplicas", 0) <= 15))
        durability_checks.append(rep_dur_ok)
        if rep_dur_ok:
            print(f"  ✓ 5e: Replica range stable")
        else:
            print(f"  ✗ 5e: Replica range not stable or out of range")

        # 5f: Scaling policies stable and correct on both reads
        pol_ok = (check_sd_policies(sd1) and check_sd_policies(sd2) and
                  check_su_policies(su1) and check_su_policies(su2))
        durability_checks.append(pol_ok)
        if pol_ok:
            print(f"  ✓ 5f: Scaling policies stable")
        else:
            print(f"  ✗ 5f: Scaling policies not stable or out of range")

        passed = sum(1 for c in durability_checks if c)
        subscores["config_stable_over_time"] = passed / len(durability_checks)
        print(f"  => config_stable_over_time: {passed}/{len(durability_checks)} = {subscores['config_stable_over_time']:.3f}")

    except Exception as e:
        print(f"Error checking durability: {e}")
        subscores["config_stable_over_time"] = 0.0

    weights["config_stable_over_time"] = W

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
        "hpa_scaling_stable",
        "resource_metrics_available",
        "workload_supports_autoscaling",
        "no_config_reversion",
        "config_stable_over_time",
    ]

    for key in checks:
        score = subscores.get(key, 0)
        pct = f"{score:.0%}"
        if score >= 1.0:
            feedback_lines.append(f"✅ {key} ({pct})")
        elif score > 0:
            feedback_lines.append(f"⚠️ {key} ({pct})")
        else:
            feedback_lines.append(f"❌ {key} ({pct})")

    feedback = "\n".join(feedback_lines)

    return GradingResult(
        score=round(total_score, 3),
        subscores=subscores,
        weights=weights,
        feedback=feedback
    )
