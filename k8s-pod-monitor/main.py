import os, json, traceback, subprocess
from datetime import datetime, timedelta
from pathlib import Path

try:
    from kubernetes import client, config
except ImportError: exit("FATAL: 'kubernetes' library not found. Please run build.sh or use Docker.")

try:
    from rust_analyzer import analyze_pod_changes
    RUST_ACCELERATOR_ENABLED = True
except ImportError:
    RUST_ACCELERATOR_ENABLED = False

DATA_DIR, NORMAL_POD_PHASES = Path("data"), ["Succeeded", "Running"]

def get_all_contexts():
    try:
        return config.list_kube_config_contexts()[0]
    except config.ConfigException:
        print("WARNING: No local kubeconfig. Assuming in-cluster.")
        return [{"name": "in-cluster", "context": {"cluster": os.getenv("K8S_CLUSTER_NAME", "in-cluster")}}]
    except Exception as e:
        print(f"ERROR: Could not list kubeconfig contexts: {e}"); return []

def get_pod_events(context_name, namespace, pod_name):
    print(f"INFO: Fetching events for {namespace}/{pod_name} in context {context_name}")
    try:
        cmd = ["kubectl", "get", "events", "--namespace", namespace, "--field-selector", f"involvedObject.name={pod_name}", "-o", "json"]
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        events_data = json.loads(result.stdout)
        sorted_events = sorted(events_data.get('items', []), key=lambda e: e.get('lastTimestamp', ''), reverse=True)
        return [{"last_seen": e.get("lastTimestamp"), "type": e.get("type"), "reason": e.get("reason"), "message": e.get("message")} for e in sorted_events]
    except Exception as e:
        error_msg = f"Failed to get pod events: {e}"
        print(f"ERROR: {error_msg}"); return [{"message": error_msg, "type": "Error"}]

def check_abnormal_pods(api_client, cluster_name, context_name):
    abnormal_pods = []
    try:
        pods = api_client.list_pod_for_all_namespaces(watch=False, timeout_seconds=120)
        for pod in pods.items:
            is_abnormal = False
            pod_status = pod.status.phase
            if pod_status not in NORMAL_POD_PHASES or (pod_status == "Running" and pod.status.container_statuses and not all(cs.ready for cs in pod.status.container_statuses)):
                is_abnormal = True
            if is_abnormal:
                reasons = []
                if pod.status.reason: reasons.append(pod.status.reason)
                if pod.status.container_statuses:
                    for cs in pod.status.container_statuses:
                        state = cs.state
                        if state.waiting and state.waiting.reason: reasons.append(state.waiting.reason)
                        if state.terminated and state.terminated.reason: reasons.append(state.terminated.reason)
                        if cs.restart_count > 0: reasons.append(f"Restarts({cs.restart_count})")
                abnormal_pods.append({
                    "timestamp": datetime.now().isoformat(), "cluster": cluster_name, "context_name": context_name, 
                    "namespace": pod.metadata.namespace, "pod": pod.metadata.name, "status": pod_status, 
                    "node": pod.spec.node_name or "N/A", "reasons": ", ".join(sorted(list(set(reasons)))) or "N/A"
                })
        print(f"INFO: Scan for cluster '{cluster_name}' complete. Found {len(abnormal_pods)} abnormal pod(s).")
    except Exception as e:
        print(f"ERROR: Pod scan failed in cluster '{cluster_name}': {e}")
    return abnormal_pods

def check_all_clusters():
    all_abnormal_pods = []
    contexts = get_all_contexts()
    if not contexts: return []
    print(f"INFO: Found {len(contexts)} contexts. Starting scan...")
    for context_info in contexts:
        context_name, cluster_name = context_info['name'], context_info['context'].get('cluster', context_info['name'])
        print(f"\n--- Checking Cluster: '{cluster_name}' (Context: '{context_name}') ---")
        try:
            print(f"INFO: Forcing token refresh for context '{context_name}' via kubectl...")
            subprocess.run(["kubectl", "config", "use-context", context_name], check=True, capture_output=True, text=True)
            subprocess.run(["kubectl", "get", "ns", "--request-timeout=10s"], check=True, capture_output=True, text=True)
            print("INFO: Token refresh successful.")
            api_client = client.CoreV1Api(api_client=config.new_client_from_config(context=context_name))
            all_abnormal_pods.extend(check_abnormal_pods(api_client, cluster_name, context_name))
        except Exception as e:
            print(f"ERROR: Failed to process context '{context_name}'. Skipping. Reason: {e}")
    return all_abnormal_pods

def save_to_file(pods, date):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    filename = DATA_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.json"
    try:
        with open(filename, "w", encoding="utf-8") as f: json.dump(pods, f, indent=2, ensure_ascii=False)
        print(f"\nINFO: Successfully saved aggregated data to {filename}")
    except IOError as e: print(f"ERROR: Could not write to file {filename}: {e}")

def load_from_file(date):
    filename = DATA_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.json"
    if not filename.exists(): return []
    try:
        with open(filename, "r", encoding="utf-8") as f: return json.load(f)
    except Exception as e:
        print(f"ERROR: Could not read file {filename}: {e}"); return []

def analyze_changes_python(today_pods, yesterday_pods):
    print("\n" + "="*50); print("🐍          ANALYZING IN PURE PYTHON MODE           🐍"); print("="*50)
    today_set = {(p['cluster'], p['namespace'], p['pod']) for p in today_pods}
    yesterday_set = {(p['cluster'], p['namespace'], p['pod']) for p in yesterday_pods}
    return {
        "new": [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) not in yesterday_set],
        "ongoing": [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in yesterday_set],
        "resolved": [p for p in yesterday_pods if (p['cluster'], p['namespace'], p['pod']) not in today_set]
    }

def analyze_changes(today_pods, yesterday_pods):
    if not RUST_ACCELERATOR_ENABLED:
        return analyze_changes_python(today_pods, yesterday_pods)
    try:
        print("\n" + "="*50); print("🚀        ANALYZING WITH RUST ACCELERATOR        🚀"); print("="*50)
        today_key_only = [{"cluster": p["cluster"], "namespace": p["namespace"], "pod": p["pod"]} for p in today_pods]
        yesterday_key_only = [{"cluster": p["cluster"], "namespace": p["namespace"], "pod": p["pod"]} for p in yesterday_pods]
        
        result = json.loads(analyze_pod_changes(json.dumps(today_key_only), json.dumps(yesterday_key_only)))
        new_keys = {tuple(p.values()) for p in result['new']}
        ongoing_keys = {tuple(p.values()) for p in result['ongoing']}
        resolved_keys = {tuple(p.values()) for p in result['resolved']}
        
        return {
            "new": [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in new_keys],
            "ongoing": [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in ongoing_keys],
            "resolved": [p for p in yesterday_pods if (p['cluster'], p['namespace'], p['pod']) in resolved_keys]
        }
    except Exception as e:
        print(f"\nWARNING: Rust accelerator failed: {e}. Falling back to Python."); return analyze_changes_python(today_pods, yesterday_pods)

if __name__ == "__main__":
    print("--- Kubernetes Pod Monitor (CLI Mode) ---")
    today_abnormal_pods = check_all_clusters()
    save_to_file(today_abnormal_pods, datetime.now())
    print("\n--- CLI run finished. ---")
