#!/bin/bash
# ==============================================================================
# Kubernetes Pod Monitor Hybrid Project Auto-Generator
#
# 이 스크립트는 Python/Rust 하이브리드 모니터링 시스템의 전체 프로젝트 구조와
# 모든 소스 코드를 자동으로 생성합니다.
#
# 실행 방법:
# 1. 이 파일을 create_project.sh 로 저장합니다.
# 2. chmod +x create_project.sh
# 3. ./create_project.sh
#
# 생성 후 프로젝트 실행 방법:
# 1. cd k8s-pod-monitor-hybrid
# 2. ./build.sh
# 3. ./start_monitor.sh --web  (웹 대시보드 모드)
#    또는
#    ./start_monitor.sh --cli  (콘솔 점검 모드)
# ==============================================================================

set -e

PROJECT_NAME="k8s-pod-monitor-hybrid"

# 프로젝트 디렉터리 생성
echo "🚀 프로젝트 디렉터리 '$PROJECT_NAME'를 생성합니다..."
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# 하위 디렉터리 생성
mkdir -p rust_analyzer/src templates abnormal_pod_logs

# --- Python 파일 생성 ---

# 1. main.py (CLI 모드 및 핵심 로직)
echo "📄 main.py 생성 중..."
cat <<'EOF' > main.py
import os
import sys
import argparse
import logging
from datetime import datetime, timedelta
from pathlib import Path

from kubernetes import client, config

# 로깅 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# --- Rust 모듈 로더 ---
RUST_ANALYZER = None
try:
    # 빌드된 Rust 모듈 임포트
    from rust_analyzer import analyze_pods_rust
    RUST_ANALYZER = analyze_pods_rust
    logging.info("✅ Rust 분석 모듈을 성공적으로 로드했습니다.")
except ImportError:
    logging.warning("⚠️ Rust 분석 모듈을 찾을 수 없습니다. Python 폴백 모드로 실행됩니다.")
    RUST_ANALYZER = None

# --- 설정값 ---
LOG_DIR = Path("abnormal_pod_logs")
PENDING_THRESHOLD_MINUTES = 10 # Pending 상태 임계값 (분)

# --- Python 폴백 분석 함수 ---
def analyze_pods_python(pods_data):
    """
    Python으로 Pod 상태를 분석하는 폴백 함수.
    Rust 버전과 동일한 로직을 수행합니다.
    """
    abnormal_pods = []
    now = datetime.utcnow()

    for pod in pods_data:
        pod_name = pod.get('name', 'N/A')
        namespace = pod.get('namespace', 'N/A')
        node = pod.get('node', 'N/A')
        phase = pod.get('phase', 'N/A')
        reason = pod.get('reason', 'N/A')
        start_time_str = pod.get('start_time')
        
        # Phase 기반 분석
        if phase in ['Failed', 'Unknown']:
            abnormal_pods.append(f"{namespace} | {pod_name} | {phase} | {node} | Phase: {phase} ({reason or 'N/A'})")
            continue

        if phase == 'Pending' and start_time_str:
            try:
                start_time = datetime.fromisoformat(start_time_str.replace('Z', '+00:00')).replace(tzinfo=None)
                if (now - start_time) > timedelta(minutes=PENDING_THRESHOLD_MINUTES):
                    abnormal_pods.append(f"{namespace} | {pod_name} | {phase} | {node} | Long-term Pending (> {PENDING_THRESHOLD_MINUTES} min)")
            except ValueError:
                pass # 날짜 파싱 실패 시 무시

        # 컨테이너 상태 기반 분석
        container_statuses = pod.get('container_statuses', [])
        for cs in container_statuses:
            container_name = cs.get('name', 'N/A')
            state = cs.get('state', {})
            
            if not cs.get('ready', False):
                 # Not Ready 상태가 가장 포괄적인 이상 상태일 수 있음
                reason_detail = "Container not ready"
                if 'waiting' in state and state['waiting']:
                    reason_detail = f"Waiting: {state['waiting'].get('reason', 'N/A')}"
                elif 'terminated' in state and state['terminated']:
                    reason_detail = f"Terminated: {state['terminated'].get('reason', 'N/A')} (Exit code: {state['terminated'].get('exit_code')})"
                
                abnormal_pods.append(f"{namespace} | {pod_name} | NotReady | {node} | Container '{container_name}': {reason_detail}")

            if 'waiting' in state and state['waiting']:
                wait_reason = state['waiting'].get('reason')
                if wait_reason in ['CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull']:
                     abnormal_pods.append(f"{namespace} | {pod_name} | Waiting | {node} | Container '{container_name}': {wait_reason}")
            
            if 'terminated' in state and state['terminated']:
                term_reason = state['terminated'].get('reason')
                exit_code = state['terminated'].get('exit_code')
                if term_reason == 'OOMKilled':
                    abnormal_pods.append(f"{namespace} | {pod_name} | Terminated | {node} | Container '{container_name}': OOMKilled")
                elif exit_code != 0:
                     abnormal_pods.append(f"{namespace} | {pod_name} | Terminated | {node} | Container '{container_name}': Non-zero exit code ({exit_code})")
    
    # 중복 제거
    return sorted(list(set(abnormal_pods)))


def get_all_pods_from_cluster(context):
    """지정된 컨텍스트(클러스터)에서 모든 파드 정보를 가져옵니다."""
    try:
        api_client = config.new_client_from_config(context=context)
        v1 = client.CoreV1Api(api_client)
        logging.info(f"'{context}' 클러스터에서 파드 정보를 가져오는 중...")
        pods = v1.list_pod_for_all_namespaces(watch=False, timeout_seconds=60)
        logging.info(f"'{context}' 클러스터에서 {len(pods.items)}개의 파드를 찾았습니다.")
        
        pod_list = []
        for item in pods.items:
            pod_info = {
                'name': item.metadata.name,
                'namespace': item.metadata.namespace,
                'node': item.spec.node_name,
                'phase': item.status.phase,
                'reason': item.status.reason,
                'start_time': item.status.start_time.isoformat() if item.status.start_time else None,
                'container_statuses': []
            }
            if item.status.container_statuses:
                for cs in item.status.container_statuses:
                    status_info = {
                        'name': cs.name,
                        'ready': cs.ready,
                        'state': {}
                    }
                    if cs.state.waiting:
                        status_info['state']['waiting'] = {'reason': cs.state.waiting.reason}
                    if cs.state.terminated:
                        status_info['state']['terminated'] = {'reason': cs.state.terminated.reason, 'exit_code': cs.state.terminated.exit_code}
                    pod_info['container_statuses'].append(status_info)
            pod_list.append(pod_info)
        return pod_list

    except Exception as e:
        logging.error(f"'{context}' 클러스터에 연결 중 오류 발생: {e}")
        return []

def get_abnormal_pods(use_rust=True, use_mock_data=False):
    """
    모든 클러스터에서 비정상 Pod를 스캔하고 결과를 반환합니다.
    """
    if use_mock_data:
        logging.info("--- MOCK DATA 모드로 실행 ---")
        return generate_mock_data()

    all_abnormal_pods = []
    try:
        contexts, active_context = config.list_kube_config_contexts()
        if not contexts:
            logging.error("Kubernetes 설정 파일을 찾을 수 없거나 설정된 컨텍스트가 없습니다.")
            return [], []
    except config.ConfigException:
        logging.error("Kubernetes 설정 파일을 로드할 수 없습니다. `~/.kube/config` 파일이 올바른지 확인하세요.")
        return [], []
        
    cluster_names = [c['name'] for c in contexts]
    all_pods_data = {}

    for context_name in cluster_names:
        pods_raw = get_all_pods_from_cluster(context_name)
        if pods_raw:
            all_pods_data[context_name] = pods_raw

    for cluster, pods in all_pods_data.items():
        logging.info(f"'{cluster}' 클러스터의 {len(pods)}개 파드 분석 중...")
        analyzer = RUST_ANALYZER if use_rust and RUST_ANALYZER else analyze_pods_python
        
        # Rust 분석기는 네임스페이스와 pod 이름을 분리된 필드로 기대하지 않고,
        # 문자열로 합쳐진 형태로 처리합니다. Python 폴백도 이에 맞춰 수정.
        # 이 예제에서는 분석 함수가 파드 딕셔너리 리스트를 직접 처리하도록 함.
        abnormal_list = analyzer(pods)
        
        for line in abnormal_list:
            # 포맷: 날짜 | 클러스터 | 네임스페이스 | Pod명 | 상태 | 노드 | 비정상원인
            # Rust/Python 분석기가 `네임스페이스 | Pod명 | ...` 부분을 반환
            all_abnormal_pods.append(f"{cluster} | {line}")

    return all_abnormal_pods, cluster_names

def save_results(pods):
    """분석 결과를 일별 로그 파일에 저장합니다."""
    LOG_DIR.mkdir(exist_ok=True)
    today = datetime.now().strftime('%Y%m%d')
    log_file = LOG_DIR / f"abnormal_pods_{today}.txt"
    
    with open(log_file, 'w', encoding='utf-8') as f:
        for pod_info in pods:
            now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            f.write(f"{now_str} | {pod_info}\n")
    logging.info(f"{len(pods)}개의 비정상 파드 정보를 '{log_file}'에 저장했습니다.")

def generate_mock_data():
    """테스트용 목업 데이터를 생성합니다."""
    clusters = ["prod-cluster", "dev-cluster"]
    today = datetime.now()
    yesterday = today - timedelta(days=1)
    
    # 어제 데이터 생성
    LOG_DIR.mkdir(exist_ok=True)
    yesterday_str = yesterday.strftime('%Y%m%d')
    yesterday_file = LOG_DIR / f"abnormal_pods_{yesterday_str}.txt"
    with open(yesterday_file, 'w', encoding='utf-8') as f:
        f.write(f"{yesterday.strftime('%Y-%m-%d 10:00:00')} | prod-cluster | default | old-nginx-pod | Failed | worker-1 | Phase: Failed (Error)\n")
        f.write(f"{yesterday.strftime('%Y-%m-%d 11:00:00')} | prod-cluster | monitoring | prometheus-pod | CrashLoopBackOff | worker-2 | Container 'prometheus': CrashLoopBackOff\n")
        f.write(f"{yesterday.strftime('%Y-%m-%d 12:00:00')} | dev-cluster | test | legacy-app | Terminated | worker-3 | Container 'main': Non-zero exit code (1)\n")

    # 오늘 데이터 생성
    mock_pods = [
        # 지속 이슈 (상태 동일)
        "prod-cluster | monitoring | prometheus-pod | CrashLoopBackOff | worker-2 | Container 'prometheus': CrashLoopBackOff",
        # 신규 이슈
        "prod-cluster | default | new-api-gateway | Pending | worker-1 | Long-term Pending (> 10 min)",
        "dev-cluster | default | db-sync-job-123 | Failed | worker-4 | Phase: Failed (OOMKilled)",
        "prod-cluster | kube-system | coredns-xyz | NotReady | worker-3 | Container 'coredns': Container not ready",
    ]
    return mock_pods, clusters

def main():
    """CLI 모드 실행 함수."""
    parser = argparse.ArgumentParser(description="Kubernetes Pod Monitor")
    parser.add_argument("--no-rust", action="store_true", help="Rust 분석 모듈을 사용하지 않고 Python으로만 실행합니다.")
    parser.add_argument("--mock", action="store_true", help="실제 클러스터 대신 목업 데이터를 사용합니다.")
    args = parser.parse_args()

    use_rust = not args.no_rust
    
    logging.info("=" * 50)
    logging.info("Kubernetes Pod 모니터링 시작 (CLI 모드)")
    logging.info(f"분석 엔진: {'Rust' if use_rust and RUST_ANALYZER else 'Python'}")
    logging.info("=" * 50)

    abnormal_pods, _ = get_abnormal_pods(use_rust, args.mock)

    if abnormal_pods:
        logging.info(f"총 {len(abnormal_pods)}개의 비정상 파드를 발견했습니다:")
        for pod in abnormal_pods:
            print(f"  - {pod}")
    else:
        logging.info("🎉 모든 파드가 정상 상태입니다.")

    save_results(abnormal_pods)

if __name__ == "__main__":
    main()
EOF

# 2. web_server.py (Flask 웹 대시보드)
echo "📄 web_server.py 생성 중..."
cat <<'EOF' > web_server.py
import os
import threading
import time
import logging
from datetime import datetime, timedelta
from pathlib import Path

from flask import Flask, render_template, jsonify, request
from waitress import serve

from main import get_abnormal_pods, save_results

# 로깅 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__)
LOG_DIR = Path("abnormal_pod_logs")

# --- 전역 상태 관리 ---
# 동시 접근을 막기 위한 Lock
app_state = {
    "last_check_time": None,
    "last_results": [],
    "is_checking": False,
    "check_lock": threading.Lock(),
    "use_rust": True,
    "use_mock_data": False
}

def read_log_file(date):
    """지정된 날짜의 로그 파일을 읽어 파드 정보를 반환합니다."""
    log_file = LOG_DIR / f"abnormal_pods_{date.strftime('%Y%m%d')}.txt"
    if not log_file.exists():
        return []
    
    pods = []
    with open(log_file, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split(' | ')
            if len(parts) >= 7:
                # 포맷: 날짜시간 | 클러스터명 | 네임스페이스 | Pod명 | 상태 | 노드 | 비정상원인
                pod_data = {
                    "timestamp": parts[0],
                    "cluster": parts[1],
                    "namespace": parts[2],
                    "pod_name": parts[3],
                    "status": parts[4],
                    "node": parts[5],
                    "reason": " | ".join(parts[6:]),
                }
                pods.append(pod_data)
    return pods

def compare_pod_states():
    """어제와 오늘의 파드 상태를 비교 분석합니다."""
    today = datetime.now()
    yesterday = today - timedelta(days=1)

    today_pods_raw = read_log_file(today)
    yesterday_pods_raw = read_log_file(yesterday)

    # 비교를 위해 (클러스터, 네임스페이스, 파드명)을 식별자로 사용
    today_pods = { (p['cluster'], p['namespace'], p['pod_name']): p for p in today_pods_raw }
    yesterday_pods = { (p['cluster'], p['namespace'], p['pod_name']): p for p in yesterday_pods_raw }

    today_keys = set(today_pods.keys())
    yesterday_keys = set(yesterday_pods.keys())

    new_issue_keys = today_keys - yesterday_keys
    resolved_issue_keys = yesterday_keys - today_keys
    ongoing_issue_keys = today_keys & yesterday_keys

    new_issues = [today_pods[k] for k in new_issue_keys]
    resolved_issues = [yesterday_pods[k] for k in resolved_issue_keys]
    
    ongoing_issues = []
    for key in ongoing_issue_keys:
        today_pod = today_pods[key]
        yesterday_pod = yesterday_pods[key]
        # 상태가 변경되었는지 확인
        if today_pod['status'] != yesterday_pod['status'] or today_pod['reason'] != yesterday_pod['reason']:
            today_pod['change_info'] = f"Status changed from '{yesterday_pod['status']}' to '{today_pod['status']}'"
        ongoing_issues.append(today_pod)

    return {
        "new": new_issues,
        "ongoing": ongoing_issues,
        "resolved": resolved_issues
    }

def run_check():
    """
    백그라운드에서 K8s 파드 상태를 점검하고 결과를 저장하는 함수.
    """
    with app_state["check_lock"]:
        if app_state["is_checking"]:
            logging.info("이미 점검이 진행 중입니다.")
            return
        app_state["is_checking"] = True

    logging.info("🚀 백그라운드 파드 상태 점검을 시작합니다...")
    try:
        abnormal_pods, _ = get_abnormal_pods(app_state["use_rust"], app_state["use_mock_data"])
        save_results(abnormal_pods)
        app_state["last_results"] = abnormal_pods
        app_state["last_check_time"] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        logging.info("✅ 백그라운드 점검 완료.")
    except Exception as e:
        logging.error(f"백그라운드 점검 중 오류 발생: {e}")
    finally:
        with app_state["check_lock"]:
            app_state["is_checking"] = False

def background_scheduler():
    """5분마다 주기적으로 `run_check`를 실행하는 스케줄러."""
    while True:
        run_check()
        time.sleep(300) # 5분 대기

@app.route('/')
def dashboard():
    """웹 대시보드 메인 페이지를 렌더링합니다."""
    return render_template('dashboard.html')

@app.route('/api/data')
def api_data():
    """대시보드에 필요한 모든 데이터를 JSON 형태로 제공합니다."""
    comparison_data = compare_pod_states()
    
    today_pods_raw = read_log_file(datetime.now())

    # 시각화 데이터
    status_distribution = {}
    cluster_distribution = {}
    for pod in today_pods_raw:
        status_distribution[pod['status']] = status_distribution.get(pod['status'], 0) + 1
        cluster_distribution[pod['cluster']] = cluster_distribution.get(pod['cluster'], 0) + 1

    # 시간별 추이 데이터 (지난 7일)
    trend_data = {"labels": [], "values": []}
    for i in range(6, -1, -1):
        date = datetime.now() - timedelta(days=i)
        pods_on_date = read_log_file(date)
        trend_data["labels"].append(date.strftime("%m-%d"))
        trend_data["values"].append(len(pods_on_date))

    return jsonify({
        "stats": {
            "current_issues": len(today_pods_raw),
            "total_today": len(today_pods_raw),
            "new_issues": len(comparison_data["new"]),
            "resolved_issues": len(comparison_data["resolved"]),
        },
        "comparison": comparison_data,
        "visualizations": {
            "status_distribution": {
                "labels": list(status_distribution.keys()),
                "values": list(status_distribution.values()),
            },
            "cluster_distribution": {
                "labels": list(cluster_distribution.keys()),
                "values": list(cluster_distribution.values()),
            },
            "trend": trend_data
        },
        "last_check_time": app_state["last_check_time"],
        "is_checking": app_state["is_checking"],
        "engine": "Rust" if app_state["use_rust"] and RUST_ANALYZER else "Python"
    })

@app.route('/api/run_check', methods=['POST'])
def api_run_check():
    """수동으로 파드 점검을 실행하는 API 엔드포인트."""
    if app_state["is_checking"]:
        return jsonify({"status": "already_running"}), 429
    
    # 즉각적인 응답을 위해 백그라운드에서 실행
    threading.Thread(target=run_check).start()
    return jsonify({"status": "triggered"})

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description="Kubernetes Pod Monitor Web Dashboard")
    parser.add_argument("--no-rust", action="store_true", help="Rust 분석 모듈을 사용하지 않습니다.")
    parser.add_argument("--mock", action="store_true", help="실제 클러스터 대신 목업 데이터를 사용합니다.")
    parser.add_argument("--port", type=int, default=5000, help="웹 서버가 실행될 포트")
    args = parser.parse_args()

    app_state["use_rust"] = not args.no_rust
    app_state["use_mock_data"] = args.mock
    
    # 초기 데이터 로드를 위해 서버 시작 전 한번 실행
    run_check()

    # 백그라운드 스케줄러 스레드 시작
    scheduler_thread = threading.Thread(target=background_scheduler, daemon=True)
    scheduler_thread.start()
    
    logging.info(f"🚀 웹 서버를 http://localhost:{args.port} 에서 시작합니다.")
    logging.info(f"분석 엔진: {'Rust' if app_state['use_rust'] and RUST_ANALYZER else 'Python'}")
    if app_state['use_mock_data']:
        logging.info("--- MOCK DATA 모드로 실행 중 ---")
    
    serve(app, host='0.0.0.0', port=args.port)
EOF

# --- Rust 모듈 파일 생성 ---

# 3. rust_analyzer/Cargo.toml
echo "🦀 rust_analyzer/Cargo.toml 생성 중..."
cat <<'EOF' > rust_analyzer/Cargo.toml
[package]
name = "rust_analyzer"
version = "0.1.0"
edition = "2021"

[lib]
name = "rust_analyzer"
crate-type = ["cdylib"]

[dependencies]
pyo3 = { version = "0.21.2", features = ["extension-module"] }
serde = { version = "1.0", features = ["derive"] }
pyo3-serde = "0.21.2"
chrono = "0.4"
rayon = "1.5" # 병렬 처리를 위한 라이브러리

EOF

# 4. rust_analyzer/src/lib.rs
echo "🦀 rust_analyzer/src/lib.rs 생성 중..."
cat <<'EOF' > rust_analyzer/src/lib.rs
use pyo3::prelude::*;
use serde::Deserialize;
use chrono::{DateTime, Utc, Duration};
use rayon::prelude::*; // Rayon 병렬 처리 import

const PENDING_THRESHOLD_MINUTES: i64 = 10;

// Python에서 전달받을 Pod 데이터 구조체
#[derive(Debug, Deserialize)]
struct Pod {
    name: String,
    namespace: String,
    node: Option<String>,
    phase: Option<String>,
    reason: Option<String>,
    start_time: Option<String>,
    container_statuses: Vec<ContainerStatus>,
}

#[derive(Debug, Deserialize)]
struct ContainerStatus {
    name: String,
    ready: bool,
    state: State,
}

#[derive(Debug, Deserialize)]
struct State {
    waiting: Option<WaitingState>,
    terminated: Option<TerminatedState>,
}

#[derive(Debug, Deserialize)]
struct WaitingState {
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TerminatedState {
    reason: Option<String>,
    exit_code: Option<i32>,
}

// Pod 하나를 분석하는 함수
fn analyze_single_pod(pod: &Pod) -> Vec<String> {
    let mut abnormal_reasons = Vec::new();
    let now = Utc::now();
    let node_name = pod.node.as_deref().unwrap_or("N/A");

    // Phase 기반 분석
    if let Some(phase) = &pod.phase {
        if phase == "Failed" || phase == "Unknown" {
            let reason_str = pod.reason.as_deref().unwrap_or("N/A");
            abnormal_reasons.push(format!(
                "{} | {} | {} | {} | Phase: {} ({})",
                pod.namespace, pod.name, phase, node_name, phase, reason_str
            ));
        } else if phase == "Pending" {
            if let Some(start_time_str) = &pod.start_time {
                if let Ok(start_time) = DateTime::parse_from_rfc3339(start_time_str) {
                    if now.signed_duration_since(start_time) > Duration::minutes(PENDING_THRESHOLD_MINUTES) {
                        abnormal_reasons.push(format!(
                            "{} | {} | {} | {} | Long-term Pending (> {} min)",
                            pod.namespace, pod.name, phase, node_name, PENDING_THRESHOLD_MINUTES
                        ));
                    }
                }
            }
        }
    }

    // 컨테이너 상태 기반 분석
    for cs in &pod.container_statuses {
        if !cs.ready {
            let mut reason_detail = "Container not ready".to_string();
            if let Some(waiting) = &cs.state.waiting {
                reason_detail = format!("Waiting: {}", waiting.reason.as_deref().unwrap_or("N/A"));
            } else if let Some(terminated) = &cs.state.terminated {
                reason_detail = format!(
                    "Terminated: {} (Exit code: {})",
                    terminated.reason.as_deref().unwrap_or("N/A"),
                    terminated.exit_code.map_or("N/A".to_string(), |c| c.to_string())
                );
            }
             abnormal_reasons.push(format!(
                "{} | {} | {} | {} | Container '{}': {}",
                pod.namespace, pod.name, "NotReady", node_name, cs.name, reason_detail
            ));
        }

        if let Some(waiting) = &cs.state.waiting {
            if let Some(reason) = &waiting.reason {
                if reason == "CrashLoopBackOff" || reason == "ImagePullBackOff" || reason == "ErrImagePull" {
                    abnormal_reasons.push(format!(
                        "{} | {} | {} | {} | Container '{}': {}",
                        pod.namespace, pod.name, "Waiting", node_name, cs.name, reason
                    ));
                }
            }
        }

        if let Some(terminated) = &cs.state.terminated {
            if let Some(reason) = &terminated.reason {
                if reason == "OOMKilled" {
                     abnormal_reasons.push(format!(
                        "{} | {} | {} | {} | Container '{}': {}",
                        pod.namespace, pod.name, "Terminated", node_name, cs.name, reason
                    ));
                }
            }
            if let Some(exit_code) = terminated.exit_code {
                if exit_code != 0 {
                    abnormal_reasons.push(format!(
                        "{} | {} | {} | {} | Container '{}': Non-zero exit code ({})",
                        pod.namespace, pod.name, "Terminated", node_name, cs.name, exit_code
                    ));
                }
            }
        }
    }
    
    abnormal_reasons
}


#[pyfunction]
fn analyze_pods_rust(py: Python, pods_py: Vec<PyObject>) -> PyResult<Vec<String>> {
    // Python 객체를 Rust 구조체로 병렬 변환
    let pods: Result<Vec<Pod>, _> = pods_py
        .par_iter()
        .map(|p| pyo3_serde::from_py_object(p.as_ref(py)))
        .collect();

    let pods = match pods {
        Ok(p) => p,
        Err(e) => return Err(PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to deserialize pod data: {}", e))),
    };

    // 병렬 분석 수행
    let mut all_abnormal_pods: Vec<String> = pods
        .par_iter()
        .flat_map(analyze_single_pod)
        .collect();

    // 중복 제거 및 정렬
    all_abnormal_pods.sort_unstable();
    all_abnormal_pods.dedup();

    Ok(all_abnormal_pods)
}

#[pymodule]
fn rust_analyzer(_py: Python, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(analyze_pods_rust, m)?)?;
    Ok(())
}
EOF

# --- 웹 프론트엔드 파일 생성 ---

# 5. templates/dashboard.html
echo "🎨 templates/dashboard.html 생성 중..."
cat <<'EOF' > templates/dashboard.html
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>K8s Pod Monitor Dashboard</title>
    
    <!-- Libs -->
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css"/>
    <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>

    <style>
        :root {
            --dark-bg: #1a1c23;
            --card-bg: rgba(44, 48, 61, 0.5);
            --border-color: rgba(255, 255, 255, 0.1);
            --text-color: #e0e0e0;
            --text-muted-color: #8c8f9a;
            --accent-color-1: #4a00e0;
            --accent-color-2: #8e2de2;
            --red: #e74c3c;
            --yellow: #f1c40f;
            --green: #2ecc71;
            --blue: #3498db;
        }

        body {
            background: linear-gradient(135deg, var(--accent-color-2), var(--accent-color-1));
            background-attachment: fixed;
            color: var(--text-color);
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }

        .main-container {
            background-color: var(--dark-bg);
            border-radius: 1rem;
            padding: 2rem;
            margin-top: 2rem;
            margin-bottom: 2rem;
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
        }

        /* Glassmorphism Card */
        .glass-card {
            background: var(--card-bg);
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
            border-radius: 0.75rem;
            border: 1px solid var(--border-color);
            padding: 1.5rem;
            transition: all 0.3s ease;
        }
        .glass-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 8px 20px rgba(0,0,0,0.2);
        }
        
        .stat-card h3 {
            font-size: 1rem;
            color: var(--text-muted-color);
            text-transform: uppercase;
        }
        .stat-card .stat-number {
            font-size: 2.5rem;
            font-weight: 700;
        }
        .stat-card .icon {
            font-size: 3rem;
            opacity: 0.2;
            position: absolute;
            right: 1.5rem;
            top: 50%;
            transform: translateY(-50%);
        }
        .new-issue { color: var(--red); }
        .resolved-issue { color: var(--green); }

        .btn-gradient {
            background: linear-gradient(45deg, var(--accent-color-1), var(--accent-color-2));
            border: none;
            color: white;
            transition: all 0.3s ease;
        }
        .btn-gradient:hover, .btn-gradient:focus {
            color: white;
            box-shadow: 0 0 15px rgba(142, 45, 226, 0.7);
        }
        
        .nav-tabs .nav-link {
            background: transparent;
            border: none;
            border-bottom: 2px solid transparent;
            color: var(--text-muted-color);
            border-radius: 0;
        }
        .nav-tabs .nav-link.active {
            color: var(--text-color);
            border-bottom-color: var(--accent-color-2);
        }
        .nav-tabs .nav-link#new-tab.active { border-bottom-color: var(--red); }
        .nav-tabs .nav-link#ongoing-tab.active { border-bottom-color: var(--yellow); }
        .nav-tabs .nav-link#resolved-tab.active { border-bottom-color: var(--green); }
        
        .table-dark {
            --bs-table-bg: transparent;
        }
        
        .badge {
            font-size: 0.8rem;
            padding: 0.4em 0.7em;
        }
        .bg-new { background-color: var(--red) !important; }
        .bg-ongoing { background-color: var(--yellow) !important; color: #333 !important;}
        .bg-resolved { background-color: var(--green) !important; }
        
        #loading-spinner {
            display: none;
            animation: spin 1s linear infinite;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        .status-badge {
            color: #fff;
            padding: 0.3em 0.6em;
            border-radius: 0.25rem;
            font-weight: 600;
            display: inline-block;
            min-width: 80px;
            text-align: center;
        }
        .status-Failed, .status-CrashLoopBackOff, .status-Terminated { background-color: var(--red); }
        .status-Pending, .status-Waiting, .status-ImagePullBackOff, .status-ErrImagePull { background-color: var(--yellow); color: #333;}
        .status-Unknown, .status-NotReady { background-color: #6c757d; }

    </style>
</head>
<body>
    <div class="container main-container">
        <!-- Header -->
        <header class="d-flex justify-content-between align-items-center mb-4">
            <div>
                <h1 class="mb-0"><i class="fas fa-cubes me-2"></i> K8s Pod Monitor</h1>
                <small class="text-muted" id="last-check-time">Last check: Never</small>
            </div>
            <div>
                <div class="form-check form-switch d-inline-block me-3">
                    <input class="form-check-input" type="checkbox" role="switch" id="autoRefreshSwitch" checked>
                    <label class="form-check-label" for="autoRefreshSwitch">Auto-refresh (30s)</label>
                </div>
                <button class="btn btn-gradient" id="runCheckBtn">
                    <i class="fas fa-sync" id="run-check-icon"></i>
                    <i class="fas fa-spinner" id="loading-spinner"></i>
                    <span id="run-check-text"> Run Check Now</span>
                </button>
            </div>
        </header>

        <!-- Stats Cards -->
        <div class="row g-4 mb-4">
            <div class="col-md-3">
                <div class="glass-card stat-card h-100">
                    <h3>Current Issues</h3>
                    <div class="stat-number" id="current-issues">0</div>
                    <i class="fas fa-exclamation-triangle icon"></i>
                </div>
            </div>
            <div class="col-md-3">
                <div class="glass-card stat-card h-100">
                    <h3>Total Issues Today</h3>
                    <div class="stat-number" id="total-today">0</div>
                    <i class="fas fa-bug icon"></i>
                </div>
            </div>
            <div class="col-md-3">
                <div class="glass-card stat-card h-100">
                    <h3 class="new-issue">New Issues</h3>
                    <div class="stat-number new-issue" id="new-issues">0</div>
                    <i class="fas fa-plus-circle icon new-issue"></i>
                </div>
            </div>
            <div class="col-md-3">
                <div class="glass-card stat-card h-100">
                    <h3 class="resolved-issue">Resolved Issues</h3>
                    <div class="stat-number resolved-issue" id="resolved-issues">0</div>
                    <i class="fas fa-check-circle icon resolved-issue"></i>
                </div>
            </div>
        </div>

        <!-- Visualizations -->
        <div class="row g-4 mb-4">
            <div class="col-lg-4">
                <div class="glass-card h-100">
                    <h5>Issue Distribution by Status</h5>
                    <div id="status-pie-chart" style="height: 300px;"></div>
                </div>
            </div>
            <div class="col-lg-8">
                <div class="glass-card h-100">
                    <h5>Issue Trend (Last 7 Days)</h5>
                    <div id="trend-line-chart" style="height: 300px;"></div>
                </div>
            </div>
        </div>

        <!-- Issue Tables -->
        <div class="glass-card">
            <ul class="nav nav-tabs" id="issueTabs" role="tablist">
                <li class="nav-item" role="presentation">
                    <button class="nav-link active" id="new-tab" data-bs-toggle="tab" data-bs-target="#new-tab-pane" type="button" role="tab">
                        <i class="fas fa-plus-circle me-1 text-danger"></i> New Issues <span class="badge rounded-pill bg-danger" id="new-count">0</span>
                    </button>
                </li>
                <li class="nav-item" role="presentation">
                    <button class="nav-link" id="ongoing-tab" data-bs-toggle="tab" data-bs-target="#ongoing-tab-pane" type="button" role="tab">
                        <i class="fas fa-history me-1 text-warning"></i> Ongoing Issues <span class="badge rounded-pill bg-warning text-dark" id="ongoing-count">0</span>
                    </button>
                </li>
                <li class="nav-item" role="presentation">
                    <button class="nav-link" id="resolved-tab" data-bs-toggle="tab" data-bs-target="#resolved-tab-pane" type="button" role="tab">
                        <i class="fas fa-check-circle me-1 text-success"></i> Resolved Issues <span class="badge rounded-pill bg-success" id="resolved-count">0</span>
                    </button>
                </li>
            </ul>
            <div class="tab-content" id="issueTabsContent">
                <div class="tab-pane fade show active" id="new-tab-pane" role="tabpanel">
                    <div class="table-responsive mt-3">
                        <table class="table table-dark table-hover">
                            <thead><tr><th>Cluster</th><th>Namespace</th><th>Pod Name</th><th>Status</th><th>Node</th><th>Reason</th></tr></thead>
                            <tbody id="new-issues-table"></tbody>
                        </table>
                    </div>
                </div>
                <div class="tab-pane fade" id="ongoing-tab-pane" role="tabpanel">
                    <div class="table-responsive mt-3">
                        <table class="table table-dark table-hover">
                            <thead><tr><th>Cluster</th><th>Namespace</th><th>Pod Name</th><th>Status</th><th>Node</th><th>Reason</th></tr></thead>
                            <tbody id="ongoing-issues-table"></tbody>
                        </table>
                    </div>
                </div>
                <div class="tab-pane fade" id="resolved-tab-pane" role="tabpanel">
                     <div class="table-responsive mt-3">
                        <table class="table table-dark table-hover">
                            <thead><tr><th>Cluster</th><th>Namespace</th><th>Pod Name</th><th>Last Status</th><th>Node</th><th>Last Seen</th></tr></thead>
                            <tbody id="resolved-issues-table"></tbody>
                        </table>
                    </div>
                </div>
            </div>
        </div>
        <footer class="text-center text-muted mt-4">
            Analysis Engine: <span id="analysis-engine" class="fw-bold">...</span>
        </footer>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        const API_URL = '/api/data';
        const RUN_CHECK_URL = '/api/run_check';
        let autoRefreshInterval;

        const chartLayout = {
            paper_bgcolor: 'transparent',
            plot_bgcolor: 'transparent',
            font: { color: 'var(--text-color)' },
            margin: { l: 40, r: 20, b: 40, t: 20 },
        };

        function createStatusBadge(status) {
            const sanitizedClass = status.replace(/[^a-zA-Z0-9]/g, '');
            return `<span class="status-badge status-${sanitizedClass}">${status}</span>`;
        }

        function populateTable(tableId, data, isResolved = false) {
            const tbody = document.getElementById(tableId);
            tbody.innerHTML = '';
            if (data.length === 0) {
                const colSpan = isResolved ? 6 : 6;
                tbody.innerHTML = `<tr><td colspan="${colSpan}" class="text-center text-muted">No issues found.</td></tr>`;
                return;
            }
            data.forEach(item => {
                const row = isResolved 
                    ? `<tr>
                        <td>${item.cluster}</td>
                        <td>${item.namespace}</td>
                        <td>${item.pod_name}</td>
                        <td>${createStatusBadge(item.status)}</td>
                        <td>${item.node}</td>
                        <td>${item.timestamp}</td>
                       </tr>`
                    : `<tr>
                        <td>${item.cluster}</td>
                        <td>${item.namespace}</td>
                        <td>${item.pod_name}</td>
                        <td>${createStatusBadge(item.status)}</td>
                        <td>${item.node}</td>
                        <td>${item.reason} ${item.change_info ? `<br><small class="text-warning fst-italic">${item.change_info}</small>` : ''}</td>
                       </tr>`;
                tbody.innerHTML += row;
            });
        }

        async function updateDashboard() {
            try {
                const response = await fetch(API_URL);
                if (!response.ok) throw new Error('Failed to fetch data');
                const data = await response.json();

                // Stats
                document.getElementById('current-issues').textContent = data.stats.current_issues;
                document.getElementById('total-today').textContent = data.stats.total_today;
                document.getElementById('new-issues').textContent = data.stats.new_issues;
                document.getElementById('resolved-issues').textContent = data.stats.resolved_issues;
                document.getElementById('last-check-time').textContent = `Last check: ${data.last_check_time || 'Never'} | Engine: ${data.engine}`;

                // Counts on tabs
                document.getElementById('new-count').textContent = data.comparison.new.length;
                document.getElementById('ongoing-count').textContent = data.comparison.ongoing.length;
                document.getElementById('resolved-count').textContent = data.comparison.resolved.length;

                // Tables
                populateTable('new-issues-table', data.comparison.new);
                populateTable('ongoing-issues-table', data.comparison.ongoing);
                populateTable('resolved-issues-table', data.comparison.resolved, true);

                // Charts
                const viz = data.visualizations;
                if (viz.status_distribution.labels.length > 0) {
                    Plotly.react('status-pie-chart', [{
                        values: viz.status_distribution.values,
                        labels: viz.status_distribution.labels,
                        type: 'pie',
                        hole: .4,
                        marker: {
                            colors: ['#e74c3c', '#f1c40f', '#3498db', '#9b59b6', '#e67e22', '#1abc9c']
                        }
                    }], chartLayout, {responsive: true});
                } else {
                     document.getElementById('status-pie-chart').innerHTML = '<div class="d-flex align-items-center justify-content-center h-100 text-muted">No data for chart</div>';
                }

                Plotly.react('trend-line-chart', [{
                    x: viz.trend.labels,
                    y: viz.trend.values,
                    type: 'scatter',
                    mode: 'lines+markers',
                    line: { shape: 'spline', color: 'var(--accent-color-2)' }
                }], chartLayout, {responsive: true});
                
                document.getElementById('analysis-engine').textContent = data.engine;

            } catch (error) {
                console.error("Dashboard update failed:", error);
            }
        }
        
        function setButtonLoading(isLoading) {
             document.getElementById('run-check-icon').style.display = isLoading ? 'none' : 'inline-block';
             document.getElementById('loading-spinner').style.display = isLoading ? 'inline-block' : 'none';
             document.getElementById('runCheckBtn').disabled = isLoading;
        }

        document.getElementById('runCheckBtn').addEventListener('click', async () => {
            setButtonLoading(true);
            try {
                await fetch(RUN_CHECK_URL, { method: 'POST' });
                // Give backend a moment to process before refreshing
                setTimeout(updateDashboard, 2000); 
            } catch (error) {
                console.error("Failed to trigger check:", error);
            } finally {
                // Let the data refresh handle the button state change
                setTimeout(() => setButtonLoading(false), 2000);
            }
        });

        document.getElementById('autoRefreshSwitch').addEventListener('change', (e) => {
            if (e.target.checked) {
                autoRefreshInterval = setInterval(updateDashboard, 30000);
            } else {
                clearInterval(autoRefreshInterval);
            }
        });

        // Initial load
        document.addEventListener('DOMContentLoaded', () => {
            updateDashboard();
            autoRefreshInterval = setInterval(updateDashboard, 30000); // 30 seconds
        });
    </script>
</body>
</html>
EOF

# --- 스크립트 및 설정 파일 생성 ---

# 6. build.sh
echo "🛠️ build.sh 생성 중..."
cat <<'EOF' > build.sh
#!/bin/bash
# 이 스크립트는 프로젝트 실행에 필요한 모든 의존성을 설치하고 Rust 모듈을 빌드합니다.

set -e

echo "🐍 Python 가상 환경 설정..."
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate

echo "📦 Python 의존성 설치..."
pip install --upgrade pip
pip install -r requirements.txt

echo "🦀 Rust 모듈 빌드 및 설치 (by maturin)..."
# maturin은 Rust 코드를 컴파일하고 현재 Python 환경에 맞는 라이브러리로 만들어줍니다.
maturin build --release
# 빌드된 wheel을 설치합니다.
pip install target/wheels/*.whl --force-reinstall

echo "✅ 빌드 완료! './start_monitor.sh'를 실행하여 애플리케이션을 시작하세요."
EOF

# 7. start_monitor.sh
echo "🚀 start_monitor.sh 생성 중..."
cat <<'EOF' > start_monitor.sh
#!/bin/bash
# 통합 실행 스크립트

# 가상 환경 활성화
if [ -d "venv" ]; then
    source venv/bin/activate
else
    echo "가상 환경(venv)이 없습니다. 먼저 ./build.sh 를 실행하세요."
    exit 1
fi

MODE="--cli"
ARGS=""

# 인자 파싱
for arg in "$@"
do
    case $arg in
        --web)
        MODE="--web"
        shift
        ;;
        --cli)
        MODE="--cli"
        shift
        ;;
        *)
        ARGS="$ARGS $arg"
        shift
        ;;
    esac
done

if [ "$MODE" == "--web" ]; then
    echo "🌐 웹 서버 모드로 실행합니다..."
    # web_server.py에 나머지 인자들(e.g., --no-rust, --mock)을 전달
    python3 web_server.py $ARGS
else
    echo "⌨️ CLI 모드로 실행합니다..."
    # main.py에 나머지 인자들을 전달
    python3 main.py $ARGS
fi
EOF

# 8. requirements.txt
echo "📝 requirements.txt 생성 중..."
cat <<'EOF' > requirements.txt
flask
kubernetes
maturin
waitress
pyo3
pyo3-serde
serde
rayon
chrono
EOF

# 9. Dockerfile
echo "🐳 Dockerfile 생성 중..."
cat <<'EOF' > Dockerfile
# --- Stage 1: Rust Builder ---
# Rust 코드를 컴파일하기 위한 빌드 환경
FROM rust:1.78 as builder

# 작업 디렉토리 설정 및 소스 코드 복사
WORKDIR /app
COPY ./rust_analyzer /app/rust_analyzer
COPY ./requirements.txt /app/requirements.txt

# Rust 컴파일러가 Python 헤더를 찾을 수 있도록 venv 생성
RUN python3 -m venv venv
ENV PATH="/app/venv/bin:$PATH"

# maturin 설치
RUN pip install maturin

# Rust 모듈을 Python wheel로 컴파일
# --release 플래그로 최적화된 빌드를 생성
RUN maturin build --release -o dist --find-interpreter

# --- Stage 2: Final Application ---
# 실제 애플리케이션을 실행할 경량 이미지
FROM python:3.11-slim

# 작업 디렉토리 설정
WORKDIR /app

# Python 의존성 설치
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 빌드 스테이지에서 컴파일된 Rust 모듈 (wheel 파일) 복사 및 설치
COPY --from=builder /app/dist /app/dist
RUN pip install --no-cache-dir /app/dist/*.whl

# 애플리케이션 소스 코드 복사
COPY . .

# 로그 디렉토리 생성 및 권한 설정
RUN mkdir -p /app/abnormal_pod_logs && \
    chown -R 1001:0 /app/abnormal_pod_logs && \
    chmod -R g+w /app/abnormal_pod_logs
USER 1001

# 환경 변수 설정
ENV FLASK_APP=web_server.py
ENV FLASK_RUN_HOST=0.0.0.0

# 웹 서버 실행 포트 노출
EXPOSE 5000

# 애플리케이션 실행
# waitress를 사용하여 프로덕션 환경에 적합한 방식으로 Flask 앱 실행
CMD ["waitress-serve", "--host=0.0.0.0", "--port=5000", "web_server:app"]
EOF

# 10. docker-compose.yml
echo "🐳 docker-compose.yml 생성 중..."
cat <<'EOF' > docker-compose.yml
version: '3.8'

services:
  k8s-pod-monitor:
    build: .
    container_name: k8s-pod-monitor
    ports:
      - "5000:5000"
    volumes:
      # Kubernetes 설정 파일 마운트 (로컬 Kubeconfig 사용 시)
      - ~/.kube:/home/nonroot/.kube:ro 
      # 로그 파일 영속성을 위한 볼륨
      - ./abnormal_pod_logs:/app/abnormal_pod_logs
    environment:
      # Docker 내부에서는 Kubeconfig 경로를 컨테이너 내부 경로로 지정해야 할 수 있음
      - KUBECONFIG=/home/nonroot/.kube/config
    restart: unless-stopped
    # 비루트 사용자(1001)로 실행되도록 설정
    user: "1001" 
EOF


# 11. README.md
echo "📖 README.md 생성 중..."
cat <<'EOF' > README.md
# Kubernetes Pod Monitor (Python/Rust Hybrid)

## 🎯 프로젝트 개요

Python과 Rust를 결합하여 개발된 고성능 Kubernetes Pod 모니터링 시스템입니다. 실시간 웹 대시보드를 통해 클러스터 내 비정상 파드의 상태를 추적하고, 전날과 비교 분석하여 신규, 지속, 해결된 이슈를 시각적으로 제공합니다.

![Dashboard Screenshot](https://placehold.co/1200x600/1a1c23/e0e0e0?text=Dashboard+UI+Preview)

## ✨ 주요 기능

- **하이브리드 아키텍처**: Python(메인 로직) + Rust(고성능 분석)
- **실시간 웹 대시보드**: Flask, Bootstrap 5, Plotly.js 기반의 모던 UI
- **일일 비교 분석**: 어제와 오늘을 비교하여 신규/지속/해결 이슈 추적
- **DB-Free**: 데이터를 일별 텍스트 파일로 관리하여 가볍고 빠름
- **포괄적인 이상 감지**: `Failed`, `CrashLoopBackOff`, `OOMKilled` 등 다양한 상태 감지
- **자동화**: 백그라운드 스레드를 통한 주기적 자동 점검
- **유연한 실행**: CLI 모드와 웹 대시보드 모드 지원
- **성능 및 안정성**: Rust 분석 실패 시 Python으로 자동 폴백

## 🛠️ 기술 스택

- **백엔드**: Python, Flask, Waitress
- **성능 모듈**: Rust (PyO3 바인딩)
- **프론트엔드**: HTML, CSS, JavaScript, Bootstrap 5, Plotly.js
- **빌드/패키징**: Maturin
- **컨테이너**: Docker, Docker Compose

## 🚀 시작하기

### 전제 조건

- Python 3.9+
- Rust 컴파일러 및 Cargo (https://rustup.rs/)
- `~/.kube/config` 파일에 하나 이상의 유효한 클러스터 컨텍스트 설정

### 1. 프로젝트 빌드

모든 의존성을 설치하고 Rust 모듈을 컴파일합니다.

```bash
./build.sh

2. 애플리케이션 실행
웹 대시보드 모드
# 기본 모드 (Rust 엔진 사용)
./start_monitor.sh --web

# Python 폴백 모드로 실행
./start_monitor.sh --web --no-rust

# 목업 데이터로 테스트
./start_monitor.sh --web --mock

실행 후 http://localhost:5000에 접속하여 대시보드를 확인하세요.
CLI 모드
일회성으로 비정상 파드를 점검하고 결과를 터미널에 출력합니다.
# 기본 모드
./start_monitor.sh --cli

# Python 폴백 모드
./start_monitor.sh --cli --no-rust

# 목업 데이터로 테스트
./start_monitor.sh --cli --mock

🐳 Docker로 실행하기
docker-compose를 사용하여 간편하게 컨테이너화된 애플리케이션을 실행할 수 있습니다.
docker-compose up --build
```docker-compose.yml` 파일에서 로컬 `~/.kube` 디렉토리를 컨테이너에 마운트하여 실제 클러스터에 접근합니다. In-cluster 환경에서는 볼륨 마운트 없이 서비스 어카운트를 사용하도록 수정이 필요합니다.

## 📁 프로젝트 구조


k8s-pod-monitor-hybrid/
├── main.py                 # CLI 모드 및 핵심 분석 로직
├── web_server.py           # Flask 웹 대시보드 서버
├── rust_analyzer/          # Rust 고성능 분석 모듈
│   ├── Cargo.toml
│   └── src/lib.rs
├── templates/
│   └── dashboard.html      # 웹 UI 템플릿
├── abnormal_pod_logs/      # 일별 로그 파일 저장소
├── build.sh                # 자동 빌드 스크립트
├── start_monitor.sh        # 통합 실행 스크립트
├── requirements.txt        # Python 의존성
├── Dockerfile              # Docker 이미지 빌드 파일
├── docker-compose.yml      # Docker Compose 설정
└── README.md               # 프로젝트 문서

## ⚙️ 커스터마이징

- **Pending 임계값**: `main.py`의 `PENDING_THRESHOLD_MINUTES` 변수를 수정하여 Pending 상태를 비정상으로 판단할 시간을 조절할 수 있습니다.
- **점검 주기**: `web_server.py`의 `background_scheduler` 함수 내 `time.sleep(300)` 값을 변경하여 자동 점검 주기를 조절할 수 있습니다. (기본 5분)
EOF

# 실행 권한 부여
echo "🔒 스크립트 파일에 실행 권한을 부여합니다..."
chmod +x build.sh start_monitor.sh

cd ..
echo ""
echo "✅ 프로젝트 생성이 완료되었습니다!"
echo "다음 단계를 진행하세요:"
echo "1. cd $PROJECT_NAME"
echo "2. ./build.sh"
echo "3. ./start_monitor.sh --web --mock (목업 데이터로 웹 대시보드 테스트)"
echo "   또는"
echo "   ./start_monitor.sh --web (실제 클러스터에 연결)"


