#!/bin/bash
# =================================================================
# Kubernetes Pod Monitor 전체 프로젝트 생성 스크립트 (v1.5 - 실행 모드 피드백 강화)
# 이 스크립트는 k8s-pod-monitor 디렉터리를 생성하고
# 모든 소스 코드와 설정 파일을 자동으로 작성합니다.
# 실행 권한 부여 후 실행하세요: chmod +x create_k8s_monitor.sh && ./create_k8s_monitor.sh
# =================================================================

# --- 변수 정의 ---
PROJECT_DIR="k8s-pod-monitor"

# --- 프로젝트 디렉터리 생성 ---
echo "INFO: Creating project directory: ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}" || { echo "ERROR: Failed to enter directory ${PROJECT_DIR}. Aborting."; exit 1; }

# --- 주요 디렉터리 생성 ---
mkdir -p "templates"
mkdir -p "rust_analyzer/src"
mkdir -p "data"

# --- 1. requirements.txt 생성 ---
echo "INFO: Creating requirements.txt..."
cat << 'EOF' > requirements.txt
kubernetes==28.1.0
requests==2.31.0
flask==2.3.2
flask-cors==4.0.0
plotly==5.15.0
maturin==1.2.3
EOF

# --- 2. rust_analyzer/Cargo.toml 생성 ---
echo "INFO: Creating rust_analyzer/Cargo.toml..."
cat << 'EOF' > rust_analyzer/Cargo.toml
[package]
name = "rust_analyzer"
version = "0.1.0"
edition = "2021"

[lib]
name = "rust_analyzer"
crate-type = ["cdylib"]

[dependencies]
pyo3 = { version = "0.20", features = ["extension-module"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
chrono = { version = "0.4", features = ["serde"] }
EOF

# --- 3. rust_analyzer/src/lib.rs 생성 ---
echo "INFO: Creating rust_analyzer/src/lib.rs..."
cat << 'EOF' > rust_analyzer/src/lib.rs
use pyo3::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Serialize, Deserialize, Debug, Clone, Hash, Eq, PartialEq)]
struct PodInfo {
    cluster: String,
    namespace: String,
    pod: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct AnalysisResult {
    new: Vec<PodInfo>,
    ongoing: Vec<PodInfo>,
    resolved: Vec<PodInfo>,
}

#[pyfunction]
fn analyze_pod_changes(today_pods_str: String, yesterday_pods_str: String) -> PyResult<String> {
    let today_pods: Vec<PodInfo> = serde_json::from_str(&today_pods_str)
        .map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to parse today's pods JSON: {}", e)))?;
    let yesterday_pods: Vec<PodInfo> = serde_json::from_str(&yesterday_pods_str)
        .map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to parse yesterday's pods JSON: {}", e)))?;

    let today_set: HashSet<PodInfo> = today_pods.into_iter().collect();
    let yesterday_set: HashSet<PodInfo> = yesterday_pods.into_iter().collect();

    let new: Vec<PodInfo> = today_set.difference(&yesterday_set).cloned().collect();
    let ongoing: Vec<PodInfo> = today_set.intersection(&yesterday_set).cloned().collect();
    let resolved: Vec<PodInfo> = yesterday_set.difference(&today_set).cloned().collect();

    let result = AnalysisResult { new, ongoing, resolved };

    serde_json::to_string(&result)
        .map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to serialize result to JSON: {}", e)))
}

#[pymodule]
fn rust_analyzer(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(analyze_pod_changes, m)?)?;
    Ok(())
}
EOF

# --- 4. build.sh 생성 ---
echo "INFO: Creating build.sh..."
cat << 'EOF' > build.sh
#!/bin/bash
set -e
echo "STEP 1: Setting up Python virtual environment..."
if [ ! -d "venv" ]; then
    echo "  - Creating virtual environment 'venv'..."
    python3 -m venv venv
else
    echo "  - Virtual environment 'venv' already exists."
fi

if [[ "$OSTYPE" == "linux-gnu"* || "$OSTYPE" == "darwin"* ]]; then
    source venv/bin/activate
elif [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    source venv/Scripts/activate
else
    echo "WARNING: Unsupported OS for venv activation. Please activate manually."
fi
echo "  - Virtual environment activated."

echo "STEP 2: Installing Python dependencies from requirements.txt..."
pip install --upgrade pip
pip install -r requirements.txt
echo "  - Python dependencies installed successfully."

echo "STEP 3: Attempting to build optional Rust accelerator module..."
if command -v cargo &> /dev/null; then
    echo "  - Rust toolchain (cargo) found."
    echo "  - Building Rust module with maturin..."
    if maturin build --release --strip --manifest-path rust_analyzer/Cargo.toml; then
        echo "  - Rust module built successfully!"
        WHEEL_FILE=$(find target/wheels -name "*.whl" | head -n 1)
        if [ -f "$WHEEL_FILE" ]; then
            echo "  - Installing Rust module: $WHEEL_FILE"
            pip install "$WHEEL_FILE" --force-reinstall
            echo "  - Rust module installed into virtual environment."
        else
            echo "WARNING: Build succeeded but no wheel file found. Continuing in pure Python mode."
        fi
    else
        echo "===================================================================="
        echo "WARNING: Rust module build failed. This is not a critical error."
        echo "  - The application will run in PURE PYTHON mode."
        echo "===================================================================="
    fi
else
    echo "===================================================================="
    echo "WARNING: Rust toolchain (cargo) not found. Skipping Rust module build."
    echo "  - The application will run in PURE PYTHON mode."
    echo "===================================================================="
fi
echo "Build process complete."
EOF

# --- 5. main.py 생성 (CLI 모드) ---
echo "INFO: Creating main.py (v1.5 - Enhanced Terminal Feedback)..."
cat << 'EOF' > main.py
import os
import json
import traceback
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
            print("WARNING: No contexts found in kubeconfig. Assuming in-cluster.")
            return [{"name": "in-cluster", "context": {"cluster": os.getenv("K8S_CLUSTER_NAME", "in-cluster")}}]
        return contexts
    except ConfigException:
        print("INFO: Could not load local kubeconfig. Assuming single, in-cluster context.")
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
                for cs in pod.status.container_statuses:
                    if not cs.ready:
                        is_abnormal = True
                        break
            if is_abnormal:
                reasons = []
                if pod.status.reason:
                    reasons.append(pod.status.reason)
                if pod.status.container_statuses:
                    for cs in pod.status.container_statuses:
                        state = cs.state
                        if state.waiting and state.waiting.reason:
                            reasons.append(state.waiting.reason)
                        if state.terminated and state.terminated.reason:
                            reasons.append(state.terminated.reason)
                        if cs.restart_count > 0:
                            reasons.append(f"Restarts({cs.restart_count})")
                unique_reasons = sorted(list(set(reasons)))
                pod_info = {
                    "timestamp": datetime.now().isoformat(), "cluster": cluster_name,
                    "namespace": pod.metadata.namespace, "pod": pod.metadata.name,
                    "status": pod_status, "node": pod.spec.node_name or "N/A",
                    "reasons": ", ".join(unique_reasons) or "N/A"
                }
                abnormal_pods.append(pod_info)
        print(f"INFO: Scan for cluster '{cluster_name}' complete. Found {len(abnormal_pods)} abnormal pod(s).")
    except ApiException as e:
        print(f"ERROR: Kubernetes API error in cluster '{cluster_name}': {e.reason} (Code: {e.status})")
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during pod scan in cluster '{cluster_name}': {e}")
        traceback.print_exc()
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
            api_client = client.CoreV1Api(api_client=config.new_client_from_config(context=context_name)) if context_name != "in-cluster" else config.load_incluster_config() and client.CoreV1Api()
            cluster_pods = check_abnormal_pods(api_client, cluster_name)
            all_abnormal_pods.extend(cluster_pods)
        except Exception as e:
            print(f"ERROR: Failed to process context '{context_name}'. Skipping. Reason: {e}")
            continue
    return all_abnormal_pods

def save_to_file(pods, date):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    filename = DATA_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.json"
    temp_filename = filename.with_suffix(".tmp")
    try:
        with open(temp_filename, "w", encoding="utf-8") as f:
            json.dump(pods, f, indent=2, ensure_ascii=False)
        os.replace(temp_filename, filename)
        print(f"\nINFO: Successfully saved aggregated data to {filename}")
    except IOError as e:
        print(f"ERROR: Could not write to file {filename}: {e}")

def load_from_file(date):
    filename = DATA_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.json"
    if not filename.exists(): return []
    try:
        with open(filename, "r", encoding="utf-8") as f: return json.load(f)
    except (IOError, json.JSONDecodeError) as e:
        print(f"ERROR: Could not read or parse file {filename}: {e}")
        return []

def analyze_changes_python(today_pods, yesterday_pods):
    print("\n" + "="*50)
    print("🐍          ANALYZING IN PURE PYTHON MODE           🐍")
    print("="*50)
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
        print("\n" + "="*50)
        print("🚀        ANALYZING WITH RUST ACCELERATOR        🚀")
        print("="*50)
        today_key_only = [{"cluster": p["cluster"], "namespace": p["namespace"], "pod": p["pod"]} for p in today_pods]
        yesterday_key_only = [{"cluster": p["cluster"], "namespace": p["namespace"], "pod": p["pod"]} for p in yesterday_pods]
        result_json = analyze_pod_changes(json.dumps(today_key_only), json.dumps(yesterday_key_only))
        rust_result = json.loads(result_json)
        
        new_keys = set(tuple(p.values()) for p in rust_result['new'])
        resolved_keys = set(tuple(p.values()) for p in rust_result['resolved'])
        ongoing_keys = set(tuple(p.values()) for p in rust_result['ongoing'])

        new = [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in new_keys]
        resolved = [p for p in yesterday_pods if (p['cluster'], p['namespace'], p['pod']) in resolved_keys]
        ongoing = [p for p in today_pods if (p['cluster'], p['namespace'], p['pod']) in ongoing_keys]
        
        return {"new": new, "ongoing": ongoing, "resolved": resolved}
    except Exception as e:
        print(f"\nWARNING: Rust accelerator failed: {e}. Falling back to Python implementation.")
        return analyze_changes_python(today_pods, yesterday_pods)

if __name__ == "__main__":
    print("--- Kubernetes Pod Monitor (CLI Mode) - Multi-Cluster ---")
    today_abnormal_pods = check_all_clusters()
    today_date = datetime.now()
    save_to_file(today_abnormal_pods, today_date)

    yesterday_date = today_date - timedelta(days=1)
    yesterday_abnormal_pods = load_from_file(yesterday_date)
    analysis = analyze_changes(today_abnormal_pods, yesterday_abnormal_pods)

    print("\n" + "="*50)
    print("      Multi-Cluster Daily Pod Status Summary")
    print("="*50)
    print(f"Date: {today_date.strftime('%Y-%m-%d')}")
    print(f"Total Abnormal Pods (all clusters): {len(today_abnormal_pods)}")
    print(f"  - New Issues: {len(analysis['new'])}")
    print(f"  - Ongoing Issues: {len(analysis['ongoing'])}")
    print(f"  - Resolved Issues: {len(analysis['resolved'])}")
    print("="*50 + "\n")

    for p_type, p_list in analysis.items():
        if p_list:
            print(f"--- [{p_type.upper()}] Abnormal Pods ---")
            for p in p_list:
                print(f"  - [{p['cluster']}] {p['namespace']}/{p['pod']} (Status: {p['status']}) on node {p['node']} | Reasons: {p['reasons']}")
    
    print("\n--- CLI run finished. ---")
EOF

# --- 6. web_server.py 생성 (웹 대시보드) ---
echo "INFO: Creating web_server.py (v1.5)..."
cat << 'EOF' > web_server.py
import threading
import time
import json
from datetime import datetime, timedelta
from pathlib import Path

try:
    from flask import Flask, render_template, jsonify
    from flask_cors import CORS
except ImportError:
    print("ERROR: 'flask' or 'flask-cors' not found.")
    exit(1)

from main import check_all_clusters, save_to_file, load_from_file, analyze_changes

app = Flask(__name__)
CORS(app)

background_task_lock = threading.Lock()
background_thread_status = {"running": False, "last_run": "Never", "last_result": "N/A"}
cached_data = {}

@app.route('/')
def dashboard():
    return render_template('dashboard.html')

@app.route('/api/data')
def get_api_data():
    global cached_data
    if not cached_data:
        print("INFO: No cached data found. Running initial scan...")
        run_monitor_check()
    response_data = cached_data.copy()
    response_data['background_status'] = background_thread_status
    return jsonify(response_data)

@app.route('/api/run-check', methods=['POST'])
def force_run_check():
    if background_task_lock.locked():
        return jsonify({"status": "error", "message": "A scan is already in progress."}), 429
    thread = threading.Thread(target=run_monitor_check)
    thread.start()
    return jsonify({"status": "success", "message": "A new multi-cluster pod scan has been initiated."})

def run_monitor_check():
    global cached_data
    with background_task_lock:
        print("INFO: Acquiring lock for multi-cluster monitor check...")
        background_thread_status["running"] = True
        today = datetime.now()
        try:
            today_pods = check_all_clusters()
            save_to_file(today_pods, today)
        except Exception as e:
            background_thread_status["last_result"] = f"Failed: Error during multi-cluster scan: {e}"
            background_thread_status["running"] = False
            print(f"ERROR: Multi-cluster scan failed: {e}")
            return
        
        yesterday = today - timedelta(days=1)
        yesterday_pods = load_from_file(yesterday)
        analysis_result = analyze_changes(today_pods, yesterday_pods)
        cached_data = format_data_for_dashboard(today_pods, analysis_result)
        
        background_thread_status["last_run"] = today.strftime('%Y-%m-%d %H:%M:%S')
        background_thread_status["last_result"] = "Success"
        background_thread_status["running"] = False
        print("INFO: Multi-cluster monitor check completed and data cached.")

def format_data_for_dashboard(today_pods, analysis):
    status_counts, cluster_counts = {}, {}
    for pod in today_pods:
        status_counts[pod['status']] = status_counts.get(pod['status'], 0) + 1
        cluster_counts[pod['cluster']] = cluster_counts.get(pod['cluster'], 0) + 1
    return {
        "stats": {"total": len(today_pods), "new": len(analysis['new']), "ongoing": len(analysis['ongoing']), "resolved": len(analysis['resolved'])},
        "lists": analysis,
        "charts": {
            "status_distribution": {"labels": list(status_counts.keys()), "values": list(status_counts.values())},
            "cluster_distribution": {"labels": list(cluster_counts.keys()), "values": list(cluster_counts.values())}
        },
        "last_updated": datetime.now().isoformat()
    }

def background_scheduler():
    print("INFO: Background scheduler started. Will run checks every 10 minutes.")
    while True:
        run_monitor_check()
        time.sleep(600)

if __name__ == '__main__':
    port = 5000
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        if s.connect_ex(('localhost', port)) == 0:
            print(f"ERROR: Port {port} is already in use.")
            exit(1)
    print("INFO: Starting initial data load before launching web server...")
    run_monitor_check()
    scheduler_thread = threading.Thread(target=background_scheduler, daemon=True)
    scheduler_thread.start()
    print(f"INFO: Starting Flask web server on http://localhost:{port}")
    app.run(host='0.0.0.0', port=port, debug=False)
EOF

# --- 7. templates/dashboard.html 생성 ---
echo "INFO: Creating templates/dashboard.html..."
cat << 'EOF' > templates/dashboard.html
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kubernetes Pod Monitor</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <script src="https://cdn.plot.ly/plotly-2.32.0.min.js"></script>
    <style>
        body{background-color:#f8f9fa}.card{box-shadow:0 2px 4px rgba(0,0,0,.1)}.stat-card .card-title{font-size:1.1rem;color:#6c757d}.stat-card .card-text{font-size:2.5rem;font-weight:700}.table-responsive{max-height:400px}.nav-tabs .nav-link{color:#495057}.nav-tabs .nav-link.active{color:#0d6efd;font-weight:700}#loading-spinner{position:fixed;top:50%;left:50%;z-index:1050;transform:translate(-50%,-50%)}.table th:first-child,.table td:first-child{width:15%}.badge.bg-danger{background-color:#dc3545!important}.badge.bg-warning{background-color:#ffc107!important}.badge.bg-info{background-color:#0dcaf0!important}.badge.bg-success{background-color:#198754!important}
    </style>
</head>
<body>
    <div id="loading-spinner" class="spinner-border text-primary" role="status" style="display:none"><span class="visually-hidden">Loading...</span></div>
    <div class="container-fluid mt-4">
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h1 class="h3">📊 Kubernetes Pod Monitor (Multi-Cluster)</h1>
            <div><button id="force-refresh-btn" class="btn btn-primary">🔄 Force Refresh</button></div>
        </div>
        <div class="row mb-3"><div class="col"><small class="text-muted">Last Updated: <span id="last-updated">N/A</span> | Background Status: <span id="background-status">N/A</span></small></div></div>
        <div class="row mb-4">
            <div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">🚨 Total Abnormal Pods</h5><p id="stat-total" class="card-text text-danger">0</p></div></div></div>
            <div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">✨ New Issues (Today)</h5><p id="stat-new" class="card-text text-warning">0</p></div></div></div>
            <div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">⏳ Ongoing Issues</h5><p id="stat-ongoing" class="card-text text-info">0</p></div></div></div>
            <div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">✅ Resolved Issues</h5><p id="stat-resolved" class="card-text text-success">0</p></div></div></div>
        </div>
        <div class="row mb-4">
            <div class="col-lg-6 mb-3"><div class="card h-100"><div class="card-header">Status Distribution</div><div class="card-body"><div id="chart-status-distribution"></div></div></div></div>
            <div class="col-lg-6 mb-3"><div class="card h-100"><div class="card-header">Abnormal Pods by Cluster</div><div class="card-body"><div id="chart-cluster-distribution"></div></div></div></div>
        </div>
        <div class="card">
            <div class="card-header">
                <ul class="nav nav-tabs card-header-tabs">
                    <li class="nav-item"><a class="nav-link active" data-bs-toggle="tab" href="#tab-new">New <span id="badge-new" class="badge bg-warning"></span></a></li>
                    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-ongoing">Ongoing <span id="badge-ongoing" class="badge bg-info"></span></a></li>
                    <li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-resolved">Resolved <span id="badge-resolved" class="badge bg-success"></span></a></li>
                </ul>
            </div>
            <div class="card-body"><div class="tab-content">
                <div class="tab-pane fade show active" id="tab-new"><div class="table-responsive"><table class="table table-striped table-hover"><thead><tr><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Status</th><th>Node</th><th>Reasons</th><th>Timestamp</th></tr></thead><tbody id="table-body-new"></tbody></table></div></div>
                <div class="tab-pane fade" id="tab-ongoing"><div class="table-responsive"><table class="table table-striped table-hover"><thead><tr><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Status</th><th>Node</th><th>Reasons</th><th>Timestamp</th></tr></thead><tbody id="table-body-ongoing"></tbody></table></div></div>
                <div class="tab-pane fade" id="tab-resolved"><div class="table-responsive"><table class="table table-striped table-hover"><thead><tr><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Status</th><th>Node</th><th>Reasons</th><th>Timestamp</th></tr></thead><tbody id="table-body-resolved"></tbody></table></div></div>
            </div></div>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
    document.addEventListener('DOMContentLoaded',function(){const e="/api/data",t="/api/run-check",n=document.getElementById("loading-spinner");function a(){n.style.display="block"}function o(){n.style.display="none"}function i(e){const t=e.status==="Running"?"bg-warning":"bg-danger";return`<tr><td><b>${e.cluster||"N/A"}</b></td><td>${e.namespace||"N/A"}</td><td>${e.pod||"N/A"}</td><td><span class="badge ${t}">${e.status||"N/A"}</span></td><td>${e.node||"N/A"}</td><td>${e.reasons||"N/A"}</td><td>${e.timestamp?new Date(e.timestamp).toLocaleString():"N/A"}</td></tr>`}async function d(){try{const t=await fetch(e);if(!t.ok)throw new Error(`HTTP error! status: ${t.status}`);(e=>{document.getElementById("stat-total").textContent=e.stats.total,document.getElementById("stat-new").textContent=e.stats.new,document.getElementById("stat-ongoing").textContent=e.stats.ongoing,document.getElementById("stat-resolved").textContent=e.stats.resolved,document.getElementById("badge-new").textContent=e.stats.new,document.getElementById("badge-ongoing").textContent=e.stats.ongoing,document.getElementById("badge-resolved").textContent=e.stats.resolved,document.getElementById("table-body-new").innerHTML=e.lists.new.map(i).join(""),document.getElementById("table-body-ongoing").innerHTML=e.lists.ongoing.map(i).join(""),document.getElementById("table-body-resolved").innerHTML=e.lists.resolved.map(i).join("");const t={margin:{l:40,r:20,t:40,b:20},height:300};Plotly.newPlot("chart-status-distribution",[{labels:e.charts.status_distribution.labels,values:e.charts.status_distribution.values,type:"pie",hole:.4}],t,{responsive:!0,displaylogo:!1}),Plotly.newPlot("chart-cluster-distribution",[{x:e.charts.cluster_distribution.labels,y:e.charts.cluster_distribution.values,type:"bar",marker:{color:"#0d6efd"}}],t,{responsive:!0,displaylogo:!1}),document.getElementById("last-updated").textContent=new Date(e.last_updated).toLocaleString(),e.background_status&&(document.getElementById("background-status").textContent=`${e.background_status.last_run} (${e.background_status.last_result}`)})(await t.json())}catch(e){console.error("Failed to fetch data:",e),alert("Failed to load dashboard data. Please check server logs.")}}a(),d().finally(o),setInterval(d,6e4),document.getElementById("force-refresh-btn").addEventListener("click",async function(){a(),document.getElementById("force-refresh-btn").disabled=!0;try{const e=await fetch(t,{method:"POST"}),n=await e.json();if(!e.ok)throw new Error(n.message||"Failed to start refresh.");alert(n.message),setTimeout(()=>d().finally(()=>{o(),document.getElementById("force-refresh-btn").disabled=!1}),3e3)}catch(e){console.error("Failed to force refresh:",e),alert(`Error: ${e.message}`),o(),document.getElementById("force-refresh-btn").disabled=!1}})});
    </script>
</body>
</html>
EOF

# --- 8. README.md 생성 ---
echo "INFO: Creating README.md (v1.5)..."
cat << 'EOF' > README.md
# Kubernetes Pod Monitor (v1.5)

**오류 없이 즉시 실행 가능한 다중 클러스터** Kubernetes Pod 모니터링 시스템입니다.
`CrashLoopBackOff`, `ImagePullBackOff`와 같이 컨테이너 레벨의 문제를 정확하게 탐지하고, 터미널에 현재 실행 모드(Rust/Python)를 명확히 표시하도록 개선되었습니다.

## 🌟 주요 기능

- **정확한 탐지 로직**: Pod의 전체 `phase`뿐만 아니라 각 **컨테이너의 개별 상태(`ready`)**까지 점검하여 `CrashLoopBackOff` 등의 숨겨진 문제를 정확히 탐지합니다.
- **명확한 실행 피드백**: 분석 시 Rust 가속 모드(🚀) 또는 순수 Python 모드(🐍)로 실행되는지 터미널에 배너를 표시하여 투명성을 높였습니다.
- **다중 클러스터 지원**: `kubeconfig`에 있는 모든 컨텍스트(클러스터)를 자동으로 순회하며 결과를 통합합니다.
- **상세한 원인 분석**: Pod의 재시작 횟수(`Restarts`) 등 더 상세한 정보를 수집하여 원인 파악을 돕습니다.

## 🔧 설치 및 실행

### 1. 프로젝트 생성 (최초 1회)
```bash
# 이 스크립트를 다운로드하여 실행하면 모든 파일이 자동으로 생성됩니다.
# (예: curl -O <script_url> && chmod +x create_k8s_monitor.sh && ./create_k8s_monitor.sh)
EOF
