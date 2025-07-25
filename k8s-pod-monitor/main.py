import os
import json
import traceback
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

try:
    from kubernetes import client, config
    from kubernetes.config.config_exception import ConfigException
    from kubernetes.client.rest import ApiException
except ImportError:
    print("ERROR: 'kubernetes' library not found.")
    print("Please run './build.sh' and activate the virtual environment ('source venv/bin/activate').")
    exit(1)

try:
    from rust_analyzer import analyze_pod_changes
    RUST_ACCELERATOR_ENABLED = True
except ImportError:
    RUST_ACCELERATOR_ENABLED = False

DATA_DIR = Path("data")
NORMAL_POD_PHASES = ["Succeeded", "Running"]

def get_all_contexts():
    try:
        contexts, _ = config.list_kube_config_contexts()
        if not contexts:
            return [{"name": "in-cluster", "context": {"cluster": os.getenv("K8S_CLUSTER_NAME", "in-cluster")}}]
        return contexts
    except ConfigException:
        return [{"name": "in-cluster", "context": {"cluster": os.getenv("K8S_CLUSTER_NAME", "in-cluster")}}]
    except Exception as e:
        print(f"ERROR: Could not list kubeconfig contexts: {e}")
        return []

def check_abnormal_pods(api_client, cluster_name):
    abnormal_pods = []
    try:
        pods = api_client.list_pod_for_all_namespaces(watch=False, timeout_seconds=120)
        for pod in pods.items:
            is_abnormal = False
            pod_status = pod.status.phase
            if pod_status not in NORMAL_POD_PHASES:
                is_abnormal = True
            if pod_status == "Running" and pod.status.container_statuses:
                if not all(cs.ready for cs in pod.status.container_statuses):
                    is_abnormal = True
            if is_abnormal:
                reasons = []
                if pod.status.reason:
                    reasons.append(pod.status.reason)
                if pod.status.container_statuses:
                    for cs in pod.status.container_statuses:
                        state = cs.state
                        if state.waiting and state.waiting.reason: reasons.append(state.waiting.reason)
                        if state.terminated and state.terminated.reason: reasons.append(state.terminated.reason)
                        if cs.restart_count > 0: reasons.append(f"Restarts({cs.restart_count})")
                pod_info = {
                    "timestamp": datetime.now().isoformat(), "cluster": cluster_name,
                    "namespace": pod.metadata.namespace, "pod": pod.metadata.name,
                    "status": pod_status, "node": pod.spec.node_name or "N/A",
                    "reasons": ", ".join(sorted(list(set(reasons)))) or "N/A"
                }
                abnormal_pods.append(pod_info)
        print(f"INFO: Scan for cluster '{cluster_name}' complete. Found {len(abnormal_pods)} abnormal pod(s).")
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during pod scan in cluster '{cluster_name}': {e}")
    return abnormal_pods

def check_all_clusters():
    all_abnormal_pods = []
    contexts = get_all_contexts()
    if not contexts:
        print("ERROR: No Kubernetes contexts found to check.")
        return []
    
    print(f"INFO: Found {len(contexts)} contexts. Starting scan...")
    for context_info in contexts:
        context_name = context_info['name']
        cluster_name = context_info['context'].get('cluster', context_name)
        print(f"\n--- Checking Cluster: '{cluster_name}' (Context: '{context_name}') ---")
        try:
            if context_name == "in-cluster":
                config.load_incluster_config()
                api_client = client.CoreV1Api()
            else:
                print(f"INFO: Forcing token refresh for context '{context_name}' via kubectl...")
                subprocess.run(
                    ["kubectl", "config", "use-context", context_name],
                    check=True, capture_output=True, text=True
                )
                subprocess.run(
                    ["kubectl", "get", "ns", "--request-timeout=10s"],
                    check=True, capture_output=True, text=True
                )
                print("INFO: Token refresh successful.")
                api_client = client.CoreV1Api(api_client=config.new_client_from_config(context=context_name))
            
            cluster_pods = check_abnormal_pods(api_client, cluster_name)
            all_abnormal_pods.extend(cluster_pods)
        
        except subprocess.CalledProcessError as e:
            print(f"ERROR: 'kubectl' command failed for context '{context_name}'. Skipping.")
            print(f"       REASON: {e.stderr.strip()}")
            continue
        except Exception as e:
            print(f"ERROR: Failed to process context '{context_name}'. Skipping. Reason: {e}")
            traceback.print_exc()
            continue
    return all_abnormal_pods

def save_to_file(pods, date):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    filename = DATA_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.json"
    temp_filename = filename.with_suffix(".tmp")
    try:
        with open(temp_filename, "w", encoding="utf-8") as f: json.dump(pods, f, indent=2, ensure_ascii=False)
        os.replace(temp_filename, filename)
        print(f"\nINFO: Successfully saved aggregated data to {filename}")
    except IOError as e:
        print(f"ERROR: Could not write to file {filename}: {e}")

def load_from_file(date):
    filename = DATA_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.json"
    if not filename.exists(): return []
    try:
        with open(filename, "r", encoding="utf-8") as f: return json.load(f)
    except Exception as e:
        print(f"ERROR: Could not read or parse file {filename}: {e}")
        return []

def analyze_changes_python(today_pods, yesterday_pods):
    print("\n" + "="*50); print("🐍          ANALYZING IN PURE PYTHON MODE           🐍"); print("="*50)
    today_set = set((p['cluster'], p['namespace'], p['pod']) for p in today_pods)
    yesterday_set = set((p['cluster'], p['namespace'], p['pod']) for p in yesterday_pods)
    new_keys, resolved_keys, ongoing_keys = today_set - yesterday_set, yesterday_set - today_set, today_set.intersection(yesterday_set)
    new = [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in new_keys]
    resolved = [p for p in yesterday_pods if (p['cluster'], p['namespace'], p['pod']) in resolved_keys]
    ongoing = [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in ongoing_keys]
    return {"new": new, "ongoing": ongoing, "resolved": resolved}

def analyze_changes(today_pods, yesterday_pods):
    if not RUST_ACCELERATOR_ENABLED:
        return analyze_changes_python(today_pods, yesterday_pods)
    try:
        print("\n" + "="*50); print("🚀        ANALYZING WITH RUST ACCELERATOR        🚀"); print("="*50)
        today_key_only = [{"cluster": p["cluster"], "namespace": p["namespace"], "pod": p["pod"]} for p in today_pods]
        yesterday_key_only = [{"cluster": p["cluster"], "namespace": p["namespace"], "pod": p["pod"]} for p in yesterday_pods]
        result_json = analyze_pod_changes(json.dumps(today_key_only), json.dumps(yesterday_key_only))
        rust_result = json.loads(result_json)
        
        new_keys = {tuple(p.values()) for p in rust_result['new']}
        resolved_keys = {tuple(p.values()) for p in rust_result['resolved']}
        ongoing_keys = {tuple(p.values()) for p in rust_result['ongoing']}
        new = [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in new_keys]
        resolved = [p for p in yesterday_pods if (p['cluster'], p['namespace'], p['pod']) in resolved_keys]
        ongoing = [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in ongoing_keys]
        return {"new": new, "ongoing": ongoing, "resolved": resolved}
    except Exception as e:
        print(f"\nWARNING: Rust accelerator failed: {e}. Falling back to Python implementation.")
        return analyze_changes_python(today_pods, yesterday_pods)

if __name__ == "__main__":
    print("--- Kubernetes Pod Monitor (CLI Mode) - OIDC/Keycloak Aware ---")
    today_abnormal_pods = check_all_clusters()
    today_date = datetime.now()
    save_to_file(today_abnormal_pods, today_date)
    yesterday_date = today_date - timedelta(days=1)
    yesterday_abnormal_pods = load_from_file(yesterday_date)
    analysis = analyze_changes(today_abnormal_pods, yesterday_abnormal_pods)

    print("\n" + "="*50); print("      Multi-Cluster Daily Pod Status Summary"); print("="*50)
    print(f"Date: {today_date.strftime('%Y-%m-%d')}")
    print(f"Total Abnormal Pods (all clusters): {len(today_abnormal_pods)}")
    print(f"  - New Issues: {len(analysis['new'])}")
    print(f"  - Ongoing Issues: {len(analysis['ongoing'])}")
    print(f"  - Resolved Issues: {len(analysis['resolved'])}")
    print("="*50 + "\n")

    for p_type, p_list in analysis.items():
        if p_list:
            print(f"--- [{p_type.upper()}] Pods ---")
            for p in p_list:
                print(f"  - [{p['cluster']}] {p['namespace']}/{p['pod']} (Status: {p['status']}) | Reasons: {p['reasons']}")
    print("\n--- CLI run finished. ---")
