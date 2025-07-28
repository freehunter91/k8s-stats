#!/bin/bash
# =================================================================
# Kubernetes Pod Monitor 전체 프로젝트 생성 스크립트 (v1.7 - 로컬 실행 안정화 버전)
# 이 스크립트는 로컬 환경에서 build.sh를 통해 실행하는 프로젝트를 생성합니다.
# 실행 권한 부여 후 실행하세요: chmod +x create_k8s_monitor_v1.7.sh && ./create_k8s_monitor_v1.7.sh
# =================================================================

# --- 변수 정의 ---
PROJECT_DIR="k8s-pod-monitor-v1.7"

# --- 프로젝트 디렉터리 생성 ---
echo "INFO: Creating project directory: ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}" || { echo "ERROR: Failed to enter directory ${PROJECT_DIR}. Aborting."; exit 1; }

# --- 주요 디렉터리 생성 ---
mkdir -p "templates"
mkdir -p "rust_analyzer/src"
mkdir -p "data"

# --- 1. build.sh (로컬 실행용) 생성 ---
echo "INFO: Creating build.sh (v1.7)..."
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
        # FIX: Find the wheel inside the Rust project's target directory
        WHEEL_FILE=$(find rust_analyzer/target/wheels -name "*.whl" | head -n 1)
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


# --- 2. 애플리케이션 파일들 생성 ---
echo "INFO: Creating application source files (v1.7)..."
# requirements.txt
cat << 'EOF' > requirements.txt
kubernetes==28.1.0
requests==2.31.0
flask==2.3.2
flask-cors==4.0.0
plotly==5.15.0
maturin==1.2.3
EOF

# rust_analyzer/Cargo.toml
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

# rust_analyzer/src/lib.rs
cat << 'EOF' > rust_analyzer/src/lib.rs
use pyo3::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
#[derive(Serialize, Deserialize, Debug, Clone, Hash, Eq, PartialEq)]
struct PodInfo { cluster: String, namespace: String, pod: String }
#[derive(Serialize, Deserialize, Debug)]
struct AnalysisResult { new: Vec<PodInfo>, ongoing: Vec<PodInfo>, resolved: Vec<PodInfo> }
#[pyfunction]
fn analyze_pod_changes(today_pods_str: String, yesterday_pods_str: String) -> PyResult<String> {
    let today_pods: Vec<PodInfo> = serde_json::from_str(&today_pods_str).map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(e.to_string()))?;
    let yesterday_pods: Vec<PodInfo> = serde_json::from_str(&yesterday_pods_str).map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(e.to_string()))?;
    let today_set: HashSet<PodInfo> = today_pods.into_iter().collect();
    let yesterday_set: HashSet<PodInfo> = yesterday_pods.into_iter().collect();
    let result = AnalysisResult {
        new: today_set.difference(&yesterday_set).cloned().collect(),
        ongoing: today_set.intersection(&yesterday_set).cloned().collect(),
        resolved: yesterday_set.difference(&today_set).cloned().collect(),
    };
    serde_json::to_string(&result).map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(e.to_string()))
}
#[pymodule]
fn rust_analyzer(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(analyze_pod_changes, m)?)?;
    Ok(())
}
EOF

# main.py
cat << 'EOF' > main.py
import os, json, traceback, subprocess
from datetime import datetime, timedelta
from pathlib import Path

try:
    from kubernetes import client, config
except ImportError: exit("FATAL: 'kubernetes' library not found. Please run build.sh and activate the venv.")

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

def check_abnormal_pods(api_client, cluster_name):
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
                    "timestamp": datetime.now().isoformat(), "cluster": cluster_name,
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
            all_abnormal_pods.extend(check_abnormal_pods(api_client, cluster_name))
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
        new_keys = {(p['cluster'], p['namespace'], p['pod']) for p in result['new']}
        ongoing_keys = {(p['cluster'], p['namespace'], p['pod']) for p in result['ongoing']}
        resolved_keys = {(p['cluster'], p['namespace'], p['pod']) for p in result['resolved']}
        
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
EOF

# web_server.py
cat << 'EOF' > web_server.py
import threading, time, json
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request
from flask_cors import CORS
from main import check_all_clusters, save_to_file, load_from_file, analyze_changes

app = Flask(__name__)
CORS(app)
background_task_lock, background_thread_status, cached_data = threading.Lock(), {"running": False, "last_run": "Never", "last_result": "N/A"}, {}

@app.route('/')
def dashboard(): return render_template('dashboard.html')

@app.route('/api/data')
def get_api_data():
    if not cached_data: run_monitor_check()
    return jsonify({**cached_data, 'background_status': background_thread_status})

@app.route('/api/run-check', methods=['POST'])
def force_run_check():
    if background_task_lock.locked(): return jsonify({"status": "error", "message": "Scan in progress."}), 429
    threading.Thread(target=run_monitor_check).start()
    return jsonify({"status": "success", "message": "New scan initiated."})

def run_monitor_check():
    with background_task_lock:
        print("INFO: Acquiring lock for monitor check...")
        background_thread_status["running"] = True
        today = datetime.now()
        try:
            today_pods = check_all_clusters()
            save_to_file(today_pods, today)
        except Exception as e:
            background_thread_status.update({"last_result": f"Failed: {e}", "running": False}); return
        
        global cached_data
        cached_data = format_data_for_dashboard(today_pods, analyze_changes(today_pods, load_from_file(today - timedelta(days=1))))
        background_thread_status.update({"last_run": today.strftime('%Y-%m-%d %H:%M:%S'), "last_result": "Success", "running": False})
        print("INFO: Monitor check completed.")

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
        }, "last_updated": datetime.now().isoformat()
    }

def background_scheduler():
    print("INFO: Background scheduler started.")
    while True:
        run_monitor_check(); time.sleep(600)

if __name__ == '__main__':
    port = 5000
    run_monitor_check()
    threading.Thread(target=background_scheduler, daemon=True).start()
    print(f"INFO: Starting Flask web server on http://0.0.0.0:{port}")
    app.run(host='0.0.0.0', port=port, debug=False)
EOF

# templates/dashboard.html
cat << 'EOF' > templates/dashboard.html
<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kubernetes Pod Monitor</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet"><script src="https://cdn.plot.ly/plotly-2.32.0.min.js"></script><style>body{background-color:#f8f9fa}.card{box-shadow:0 2px 4px #0000001a}#loading-spinner{position:fixed;top:50%;left:50%;z-index:1050;transform:translate(-50%,-50%)}</style></head><body><div id="loading-spinner" class="spinner-border text-primary" role="status" style="display:none"></div><div class="container-fluid mt-4"><div class="d-flex justify-content-between align-items-center mb-4"><h1 class="h3">📊 Kubernetes Pod Monitor</h1><div><button id="force-refresh-btn" class="btn btn-primary">🔄 Force Refresh</button></div></div><div class="row mb-3"><div class="col"><small class="text-muted">Last Updated: <span id="last-updated">N/A</span> | Background Status: <span id="background-status">N/A</span></small></div></div><div class="row mb-4"><div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">🚨 Total Abnormal Pods</h5><p id="stat-total" class="card-text text-danger fs-1 fw-bold">0</p></div></div></div><div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">✨ New Issues (Today)</h5><p id="stat-new" class="card-text text-warning fs-1 fw-bold">0</p></div></div></div><div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">⏳ Ongoing Issues</h5><p id="stat-ongoing" class="card-text text-info fs-1 fw-bold">0</p></div></div></div><div class="col-lg-3 col-md-6 mb-3"><div class="card text-center h-100"><div class="card-body"><h5 class="card-title">✅ Resolved Issues</h5><p id="stat-resolved" class="card-text text-success fs-1 fw-bold">0</p></div></div></div></div><div class="row mb-4"><div class="col-lg-6 mb-3"><div class="card h-100"><div class="card-header">Status Distribution</div><div class="card-body"><div id="chart-status-distribution"></div></div></div></div><div class="col-lg-6 mb-3"><div class="card h-100"><div class="card-header">Abnormal Pods by Cluster</div><div class="card-body"><div id="chart-cluster-distribution"></div></div></div></div></div><div class="card"><div class="card-header"><ul class="nav nav-tabs card-header-tabs" id="pod-tabs"><li class="nav-item"><a class="nav-link active" data-bs-toggle="tab" href="#tab-new">New <span id="badge-new" class="badge bg-warning"></span></a></li><li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-ongoing">Ongoing <span id="badge-ongoing" class="badge bg-info"></span></a></li><li class="nav-item"><a class="nav-link" data-bs-toggle="tab" href="#tab-resolved">Resolved <span id="badge-resolved" class="badge bg-success"></span></a></li></ul></div><div class="card-body"><div class="tab-content"><div class="tab-pane fade show active" id="tab-new"><div class="table-responsive"><table class="table table-hover"><thead><tr><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Node</th><th>Status</th><th>Reasons</th></tr></thead><tbody id="table-body-new"></tbody></table></div></div><div class="tab-pane fade" id="tab-ongoing"><div class="table-responsive"><table class="table table-hover"><thead><tr><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Node</th><th>Status</th><th>Reasons</th></tr></thead><tbody id="table-body-ongoing"></tbody></table></div></div><div class="tab-pane fade" id="tab-resolved"><div class="table-responsive"><table class="table table-hover"><thead><tr><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Node</th><th>Status</th><th>Reasons</th></tr></thead><tbody id="table-body-resolved"></tbody></table></div></div></div></div></div></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script><script>
    const G={API_URL:"/api/data",REFRESH_URL:"/api/run-check",spinner:document.getElementById("loading-spinner")};function showSpinner(){G.spinner.style.display="block"}function hideSpinner(){G.spinner.style.display="none"}
    function createTableRow(p){const statusBadgeColor=p.status==="Running"?"bg-warning":"bg-danger";return`<tr><td><b>${p.cluster||"N/A"}</b></td><td>${p.namespace||"N/A"}</td><td>${p.pod||"N/A"}</td><td>${p.node||"N/A"}</td><td><span class="badge ${statusBadgeColor}">${p.status||"N/A"}</span></td><td>${p.reasons||"N/A"}</td></tr>`}
    function updateUI(data){for(const key of["total","new","ongoing","resolved"]){document.getElementById(`stat-${key}`).textContent=data.stats[key];if(key!=="total")document.getElementById(`badge-${key}`).textContent=data.stats[key]}
    for(const key of["new","ongoing","resolved"])document.getElementById(`table-body-${key}`).innerHTML=data.lists[key].map(createTableRow).join("");const chartLayout={margin:{l:40,r:20,t:40,b:20},height:300};Plotly.newPlot("chart-status-distribution",[{labels:data.charts.status_distribution.labels,values:data.charts.status_distribution.values,type:"pie",hole:.4}],chartLayout,{responsive:!0,displaylogo:!1});Plotly.newPlot("chart-cluster-distribution",[{x:data.charts.cluster_distribution.labels,y:data.charts.cluster_distribution.values,type:"bar",marker:{color:"#0d6efd"}}],chartLayout,{responsive:!0,displaylogo:!1});document.getElementById("last-updated").textContent=new Date(data.last_updated).toLocaleString();if(data.background_status)document.getElementById("background-status").textContent=`${data.background_status.last_run} (${data.background_status.last_result})`}
    async function fetchData(){try{const response=await fetch(G.API_URL);if(!response.ok)throw new Error(`HTTP error! status: ${response.status}`);updateUI(await response.json())}catch(error){console.error("Failed to fetch data:",error);alert("Failed to load dashboard data. Check server logs.")}}
    async function forceRefresh(){showSpinner();document.getElementById("force-refresh-btn").disabled=!0;try{const response=await fetch(G.REFRESH_URL,{method:"POST"}),result=await response.json();if(!response.ok)throw new Error(result.message||"Failed to start refresh.");alert(result.message);setTimeout(()=>fetchData().finally(()=>{hideSpinner();document.getElementById("force-refresh-btn").disabled=!1}),3e3)}catch(error){console.error("Failed to force refresh:",error);alert(`Error: ${error.message}`);hideSpinner();document.getElementById("force-refresh-btn").disabled=!1}}
    document.addEventListener("DOMContentLoaded",()=>{showSpinner();fetchData().finally(hideSpinner);setInterval(fetchData,6e4);document.getElementById("force-refresh-btn").addEventListener("click",forceRefresh)});
    </script></body></html>
EOF

# --- 7. README.md 생성 ---
echo "INFO: Creating README.md (v1.7)..."
cat << 'EOF' > README.md
# Kubernetes Pod Monitor (v1.7 - 로컬 실행 안정화 버전)

이 버전은 **로컬 환경에서 직접 실행**하는 것을 전제로 하며, **Docker를 사용하지 않습니다.**
`build.sh` 스크립트를 통해 개발 환경을 설정하고, Rust 모듈 빌드 경로 오류 및 OIDC 인증 문제를 해결한 안정화 버전입니다.

## 🌟 주요 기능

- **OIDC/Keycloak 인증 자동화**: 스크립트 실행 시 **자동으로 `kubectl`을 호출**하여 인증 토큰을 갱신합니다.
- **정확한 탐지 로직**: Pod의 `phase`와 각 컨테이너의 `ready` 상태까지 점검하여 `CrashLoopBackOff` 등의 문제를 정확히 탐지합니다.
- **안정적인 빌드**: Rust 모듈 빌드 시 정확한 경로를 찾아 설치하도록 `build.sh` 스크립트가 수정되었습니다.
- **다중 클러스터 지원**: `kubeconfig`에 있는 모든 컨텍스트를 자동으로 순회하며 결과를 통합합니다.
- **명확한 실행 피드백**: 분석 시 Rust 가속 모드(🚀) 또는 순수 Python 모드(🐍)로 실행되는지 터미널에 배너를 표시합니다.

## 🔧 설치 및 실행

#### 사전 요구사항
- Python 3.8+
- `kubectl`
- (선택 사항) Rust toolchain (성능 향상을 원할 경우)

#### 실행 절차
```bash
# 1. 프로젝트 생성 (최초 1회)
#    이 스크립트를 create_k8s_monitor_v1.7.sh 로 저장 후 실행
chmod +x create_k8s_monitor_v1.7.sh
./create_k8s_monitor_v1.7.sh
cd k8s-pod-monitor-v1.7

# 2. 빌드 스크립트 실행
#    가상환경 생성, 의존성 설치, Rust 모듈 컴파일을 자동으로 수행합니다.
./build.sh

# 3. 가상환경 활성화
source venv/bin/activate

# 4. 웹 대시보드 또는 CLI 실행
# 웹 대시보드 실행
python web_server.py

# CLI 모드 실행
python main.py