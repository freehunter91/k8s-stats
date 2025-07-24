#!/bin/bash

# 사용자에게서 미래라는 이름을 받은 날짜입니다.
# 2025-07-14

# 현재 사용자의 이름이 구원임을 알려줍니다.

set -e # Exit immediately if a command exits with a non-zero status.

PROJECT_DIR="k8s-pod-monitor"
RUST_DIR="$PROJECT_DIR/rust_analyzer"
RUST_SRC_DIR="$RUST_DIR/src"
TEMPLATES_DIR="$PROJECT_DIR/templates"
DATA_DIR="$PROJECT_DIR/data" # New directory for storing log files

echo "🚀 Kubernetes Pod Monitor 프로젝트를 생성합니다..."

# 프로젝트 디렉터리 생성
mkdir -p "$PROJECT_DIR"
echo "✅ 프로젝트 디렉터리 '$PROJECT_DIR' 생성 완료."

# 서브 디렉터리 생성
mkdir -p "$RUST_SRC_DIR"
echo "✅ Rust 모듈 디렉터리 '$RUST_DIR' 및 '$RUST_SRC_DIR' 생성 완료."
mkdir -p "$TEMPLATES_DIR"
echo "✅ 템플릿 디렉터리 '$TEMPLATES_DIR' 생성 완료."
mkdir -p "$DATA_DIR"
echo "✅ 데이터 저장 디렉터리 '$DATA_DIR' 생성 완료."


echo "📄 requirements.txt 파일 생성 중..."
cat << EOF > "$PROJECT_DIR/requirements.txt"
kubernetes==28.1.0
requests==2.31.0
flask==2.3.2
flask-cors==4.0.0
plotly==5.15.0
maturin==1.2.3
EOF
echo "✅ requirements.txt 생성 완료."

echo "🐍 main.py 파일 생성 중..."
cat << 'EOF' > "$PROJECT_DIR/main.py"
# main.py: Kubernetes Pod 모니터링 CLI 및 로깅 로직
import os
import sys
import logging
import json
import datetime
from pathlib import Path
from collections import defaultdict
import time

try:
    from kubernetes import client, config
    from kubernetes.client.rest import ApiException
except ImportError:
    print("오류: 'kubernetes' 라이브러리를 찾을 수 없습니다. requirements.txt를 확인하고 'pip install -r requirements.txt'를 실행해주세요.", file=sys.stderr)
    sys.exit(1)

# 로깅 설정
LOG_FILE = "monitor.log"
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

# 데이터 저장 경로 설정
# '__app_id'와 '__firebase_config'는 Canvas 환경에서 제공되는 전역 변수입니다.
# Firestore를 사용하지 않으므로, 이 변수들을 직접 사용하지는 않습니다.
# 다만, 사용자별/앱별 데이터 격리를 위해 PROJECT_DATA_DIR을 설정할 수 있습니다.
# 현재는 요청에 따라 PROJECT_DIR/data/ 에 저장합니다.
PROJECT_DATA_DIR = Path(__file__).parent / "data"
PROJECT_DATA_DIR.mkdir(parents=True, exist_ok=True) # Ensure data directory exists

def get_kube_config():
    """kubeconfig를 로드하고 현재 클러스터 이름을 반환합니다."""
    try:
        # Kubeconfig 파일 로드
        config.load_kube_config()
        # 현재 컨텍스트에서 클러스터 이름 가져오기
        current_context = config.list_kube_config_contexts()[1]
        cluster_name = current_context.get('context', {}).get('cluster', 'unknown-cluster')
        logging.info(f"kubeconfig 로드 성공. 현재 클러스터: {cluster_name}")
        return cluster_name
    except config.ConfigException as e:
        logging.error(f"kubeconfig 로드 오류: {e}. 'kubectl config view'를 실행하여 kubeconfig가 올바른지 확인해주세요.")
        return None
    except Exception as e:
        logging.error(f"알 수 없는 kubeconfig 오류: {e}")
        return None

def is_pod_abnormal(pod):
    """
    주어진 Pod 객체가 비정상 상태인지 확인합니다.
    Pod의 phase, container_statuses, conditions 등을 종합적으로 고려합니다.
    """
    status = pod.status.phase
    reasons = []

    # 1. Pod Phase 확인
    if status in ["Failed", "Pending", "Unknown"]:
        reasons.append(f"Phase is {status}")

    # 2. Conditions 확인 (Ready, Initialized, ContainersReady 등)
    if pod.status.conditions:
        for condition in pod.status.conditions:
            if condition.status == "False":
                reasons.append(f"Condition {condition.type} is False: {condition.reason or 'No reason'}")
            elif condition.type == "Ready" and condition.status == "Unknown":
                reasons.append(f"Condition Ready is Unknown: {condition.reason or 'No reason'}")


    # 3. Container Statuses 확인 (재시작, 비정상 종료)
    if pod.status.container_statuses:
        for container_status in pod.status.container_statuses:
            if not container_status.ready:
                reasons.append(f"Container {container_status.name} is not ready")
            if container_status.restart_count > 0:
                reasons.append(f"Container {container_status.name} restarted {container_status.restart_count} times")
            if container_status.state and container_status.state.waiting:
                waiting_reason = container_status.state.waiting.reason
                if waiting_reason and waiting_reason not in ["ContainerCreating", "PodInitializing"]:
                    reasons.append(f"Container {container_status.name} waiting: {waiting_reason}")
                elif waiting_reason == "ContainerCreating":
                    # Pending 상태의 경우 생성 지연을 판단 (예: 5분 초과)
                    creation_time = pod.metadata.creation_timestamp
                    if creation_time and (datetime.datetime.now(creation_time.tzinfo) - creation_time).total_seconds() > 300: # 5 minutes
                        reasons.append(f"Container {container_status.name} stuck in ContainerCreating for over 5 minutes")
            if container_status.state and container_status.state.terminated:
                if container_status.state.terminated.reason != "Completed": # Completed는 정상 종료로 간주
                    reasons.append(f"Container {container_status.name} terminated: {container_status.state.terminated.reason} (Exit Code: {container_status.state.terminated.exit_code})")

    # 고유한 이유만 반환
    return status, list(set(reasons)) if reasons else ["No specific abnormal reason detected but pod phase suggests issue."]

def get_pods_data(cluster_name):
    """
    Kubernetes 클러스터에서 모든 Pod의 상태를 가져옵니다.
    비정상 Pod만 필터링하여 반환합니다.
    """
    v1 = client.CoreV1Api()
    abnormal_pods = []
    try:
        pods = v1.list_pod_for_all_namespaces(watch=False)
        for pod in pods.items:
            pod_status_phase, abnormal_reasons = is_pod_abnormal(pod)

            # Define a threshold for "Pending" pods to be considered abnormal
            if pod_status_phase == "Pending":
                # Check if it's pending for more than X seconds (e.g., 300 seconds = 5 minutes)
                creation_time = pod.metadata.creation_timestamp
                if creation_time:
                    elapsed_seconds = (datetime.datetime.now(creation_time.tzinfo) - creation_time).total_seconds()
                    if elapsed_seconds > 300: # 5 minutes
                        abnormal_pods.append({
                            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                            "cluster": cluster_name,
                            "namespace": pod.metadata.namespace,
                            "pod": pod.metadata.name,
                            "status": pod_status_phase,
                            "node": pod.spec.node_name if pod.spec.node_name else "N/A",
                            "reasons": ", ".join(abnormal_reasons)
                        })
                else: # No creation_time, still pending
                     abnormal_pods.append({
                        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        "cluster": cluster_name,
                        "namespace": pod.metadata.namespace,
                        "pod": pod.metadata.name,
                        "status": pod_status_phase,
                        "node": pod.spec.node_name if pod.spec.node_name else "N/A",
                        "reasons": ", ".join(abnormal_reasons)
                    })
            elif pod_status_phase in ["Failed", "Unknown"] or len(abnormal_reasons) > 0:
                abnormal_pods.append({
                    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "cluster": cluster_name,
                    "namespace": pod.metadata.namespace,
                    "pod": pod.metadata.name,
                    "status": pod_status_phase,
                    "node": pod.spec.node_name if pod.spec.node_name else "N/A",
                    "reasons": ", ".join(abnormal_reasons)
                })

    except ApiException as e:
        if e.status == 403:
            logging.error(f"Kubernetes API 권한 오류 (403): 클러스터에 Pod를 나열할 권한이 없습니다. RBAC 설정을 확인하세요.")
        elif e.status == 404:
            logging.error(f"Kubernetes API 오류 (404): 요청된 리소스를 찾을 수 없습니다. API 버전 또는 클러스터 상태를 확인하세요.")
        else:
            logging.error(f"Kubernetes API 오류: {e} (Status: {e.status})")
        return []
    except Exception as e:
        logging.error(f"Pod 정보 가져오기 중 오류 발생: {e}", exc_info=True)
        return []
    return abnormal_pods

def save_abnormal_pods(abnormal_pods, filename):
    """비정상 Pod 데이터를 파일에 저장합니다."""
    file_path = PROJECT_DATA_DIR / filename
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            for pod_data in abnormal_pods:
                f.write(f"{pod_data['timestamp']} | {pod_data['cluster']} | {pod_data['namespace']} | {pod_data['pod']} | {pod_data['status']} | {pod_data['node']} | {pod_data['reasons']}\n")
        logging.info(f"비정상 Pod 데이터 '{filename}'에 저장 완료.")
        return True
    except IOError as e:
        logging.error(f"파일 쓰기 오류 ('{file_path}'): {e}")
        return False

def load_abnormal_pods(filename):
    """파일에서 비정상 Pod 데이터를 로드합니다."""
    file_path = PROJECT_DATA_DIR / filename
    pods_data = {}
    try:
        if not file_path.exists():
            return {}
        with open(file_path, 'r', encoding='utf-8') as f:
            for line in f:
                parts = line.strip().split(' | ')
                if len(parts) == 7:
                    key = f"{parts[1]}/{parts[2]}/{parts[3]}" # cluster/namespace/pod
                    pods_data[key] = {
                        "timestamp": parts[0],
                        "cluster": parts[1],
                        "namespace": parts[2],
                        "pod": parts[3],
                        "status": parts[4],
                        "node": parts[5],
                        "reasons": parts[6]
                    }
        return pods_data
    except IOError as e:
        logging.error(f"파일 읽기 오류 ('{file_path}'): {e}")
        return {}
    except Exception as e:
        logging.error(f"데이터 로드 중 오류 발생 ('{file_path}'): {e}")
        return {}

def analyze_daily_diff(today_data, yesterday_data):
    """
    어제와 오늘 데이터를 비교하여 신규, 지속, 해결된 이슈를 식별합니다.
    데이터는 cluster/namespace/pod 조합을 키로 사용합니다.
    """
    new_issues = []
    persistent_issues = []
    resolved_issues = []

    today_keys = set(today_data.keys())
    yesterday_keys = set(yesterday_data.keys())

    # 신규 이슈: 오늘 있지만 어제 없었던 것
    for key in today_keys:
        if key not in yesterday_keys:
            new_issues.append(today_data[key])

    # 지속 이슈: 오늘과 어제 모두 있었던 것
    for key in today_keys:
        if key in yesterday_keys:
            persistent_issues.append(today_data[key])

    # 해결된 이슈: 어제 있었지만 오늘 없었던 것
    for key in yesterday_keys:
        if key not in today_keys:
            resolved_issues.append(yesterday_data[key]) # 어제 데이터를 기반으로 해결됨 표시

    return new_issues, persistent_issues, resolved_issues

def run_monitor(rust_module=None):
    """
    Kubernetes Pod 모니터링을 실행하고 결과를 반환합니다.
    선택적으로 Rust 모듈을 사용할 수 있습니다.
    """
    logging.info("Kubernetes Pod 모니터링 시작...")
    cluster_name = get_kube_config()
    if not cluster_name:
        logging.error("kubeconfig를 로드할 수 없어 모니터링을 중단합니다.")
        return {
            "success": False,
            "message": "kubeconfig 설정 오류",
            "current_abnormal_pods": [],
            "new_issues": [],
            "persistent_issues": [],
            "resolved_issues": [],
            "stats": {}
        }

    current_abnormal_pods_list = get_pods_data(cluster_name)
    logging.info(f"현재 {len(current_abnormal_pods_list)}개의 비정상 Pod 감지.")

    today_filename = f"abnormal_pods_{datetime.date.today().strftime('%Y%m%d')}.txt"
    yesterday_filename = f"abnormal_pods_{(datetime.date.today() - datetime.timedelta(days=1)).strftime('%Y%m%d')}.txt"

    # Save today's data
    save_abnormal_pods(current_abnormal_pods_list, today_filename)

    # Load and process data for comparison
    today_data_dict = {f"{p['cluster']}/{p['namespace']}/{p['pod']}": p for p in current_abnormal_pods_list}
    yesterday_data_dict = load_abnormal_pods(yesterday_filename)

    new_issues, persistent_issues, resolved_issues = analyze_daily_diff(today_data_dict, yesterday_data_dict)

    # 선택적으로 Rust 모듈 사용
    if rust_module:
        try:
            # Rust 모듈에 데이터를 JSON 문자열로 전달
            # Rust 모듈의 반환값은 파이썬 객체여야 합니다 (예: dict 또는 list)
            processed_data = rust_module.analyze_pod_data_rust(json.dumps(current_abnormal_pods_list))
            logging.info("Rust 모듈을 사용하여 데이터 처리 완료.")
            # processed_data를 활용하는 로직 추가
        except Exception as e:
            logging.warning(f"Rust 모듈 실행 중 오류 발생, Python 모드로 폴백: {e}")
            # Python 처리 로직을 그대로 사용 (현재는 이 부분이 이미 기본 로직)
    else:
        logging.info("Rust 모듈을 사용할 수 없어 Python 모드로 실행합니다.")

    # 통계 계산
    stats = {
        "current_issues_count": len(current_abnormal_pods_list),
        "new_issues_count": len(new_issues),
        "persistent_issues_count": len(persistent_issues),
        "resolved_issues_count": len(resolved_issues),
        "total_issues_today": len(current_abnormal_pods_list) # Same as current_issues_count for today
    }

    # 클러스터 및 상태별 분포 계산
    status_distribution = defaultdict(int)
    cluster_distribution = defaultdict(int)
    for pod in current_abnormal_pods_list:
        status_distribution[pod['status']] += 1
        cluster_distribution[pod['cluster']] += 1

    stats["status_distribution"] = dict(status_distribution)
    stats["cluster_distribution"] = dict(cluster_distribution)

    logging.info("Kubernetes Pod 모니터링 완료.")

    return {
        "success": True,
        "message": "모니터링 성공",
        "current_abnormal_pods": current_abnormal_pods_list,
        "new_issues": new_issues,
        "persistent_issues": persistent_issues,
        "resolved_issues": resolved_issues,
        "stats": stats
    }

if __name__ == "__main__":
    # CLI 모드 실행
    print("\n--- CLI 모드: 일회성 Pod 점검 ---")
    print("주의: kubeconfig가 올바르게 설정되어 있어야 합니다.")

    try:
        # Rust 모듈 로드 시도
        try:
            # sys.path에 Rust 모듈이 빌드되는 경로 추가 (target/release 또는 target/debug)
            # maturin develop은 일반적으로 site-packages에 설치하거나,
            # 프로젝트 루트에 .so/.pyd 파일을 직접 생성합니다.
            # 여기서는 현재 디렉토리에서 찾거나, 빌드 스크립트가 적절히 처리했다고 가정합니다.
            # 실제로는 maturin 빌드 후 sys.path.append(os.path.abspath("path/to/rust_analyzer/target/debug")) 등 필요
            # 간편성을 위해, main.py와 동일 레벨에 rust_analyzer가 있고, maturin develop으로 빌드되면
            # 파이썬은 자동으로 이를 찾아 임포트할 수 있습니다.
            import rust_analyzer
            rust_enabled_module = rust_analyzer
            logging.info("Rust 모듈 'rust_analyzer' 로드 성공.")
        except ImportError:
            logging.warning("Rust 모듈 'rust_analyzer'를 찾을 수 없습니다. Python 모드로 계속 진행합니다.")
            rust_enabled_module = None
        except Exception as e:
            logging.warning(f"Rust 모듈 로드 중 예외 발생, Python 모드로 폴백: {e}")
            rust_enabled_module = None

        results = run_monitor(rust_enabled_module)

        if results["success"]:
            print("\n--- 요약 ---")
            print(f"현재 비정상 Pod 수: {results['stats'].get('current_issues_count', 0)}")
            print(f"신규 이슈 수: {results['stats'].get('new_issues_count', 0)}")
            print(f"지속 이슈 수: {results['stats'].get('persistent_issues_count', 0)}")
            print(f"해결된 이슈 수: {results['stats'].get('resolved_issues_count', 0)}")

            if results['current_abnormal_pods']:
                print("\n--- 현재 비정상 Pod 목록 ---")
                for pod in results['current_abnormal_pods']:
                    print(f"  [{pod['cluster']}/{pod['namespace']}/{pod['pod']}] Status: {pod['status']}, Node: {pod['node']}, Reasons: {pod['reasons']}")
            else:
                print("\n현재 비정상 Pod가 없습니다.")

            if results['new_issues']:
                print("\n--- 신규 이슈 (오늘 새로 발생) ---")
                for pod in results['new_issues']:
                    print(f"  [{pod['cluster']}/{pod['namespace']}/{pod['pod']}] Status: {pod['status']}, Node: {pod['node']}, Reasons: {pod['reasons']}")

            if results['persistent_issues']:
                print("\n--- 지속 이슈 (어제부터 계속되는 이슈) ---")
                for pod in results['persistent_issues']:
                    print(f"  [{pod['cluster']}/{pod['namespace']}/{pod['pod']}] Status: {pod['status']}, Node: {pod['node']}, Reasons: {pod['reasons']}")

            if results['resolved_issues']:
                print("\n--- 해결된 이슈 (어제 있었으나 오늘 해결됨) ---")
                for pod in results['resolved_issues']:
                    print(f"  [{pod['cluster']}/{pod['namespace']}/{pod['pod']}] Status: {pod['status']}, Node: {pod['node']}, Reasons: {pod['reasons']}")

        else:
            print(f"\n모니터링 실패: {results['message']}")

    except Exception as e:
        logging.critical(f"CLI 실행 중 치명적인 오류 발생: {e}", exc_info=True)
        sys.exit(1)
EOF
echo "✅ main.py 생성 완료."

echo "🌐 web_server.py 파일 생성 중..."
cat << 'EOF' > "$PROJECT_DIR/web_server.py"
# web_server.py: Flask 웹 서버 및 API 엔드포인트
import os
import sys
import json
import threading
import time
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request
from flask_cors import CORS
import logging
from collections import defaultdict

# main.py에서 run_monitor 함수를 가져오기 위해 sys.path 설정
# 현재 디렉토리가 sys.path에 포함되어 있으므로, main 모듈을 직접 임포트할 수 있습니다.
# import main
try:
    import main
    logging.info("main.py 모듈 로드 성공.")
except ImportError as e:
    logging.error(f"main.py 모듈을 로드할 수 없습니다. 경로 또는 파일 이름을 확인하세요: {e}", exc_info=True)
    sys.exit(1)

# 로깅 설정
LOG_FILE = "webserver.log"
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

app = Flask(__name__, template_folder='templates', static_folder='static')
CORS(app) # 모든 경로에 대해 CORS 허용

# 전역 변수 및 락
latest_monitor_results = {
    "success": False,
    "message": "아직 모니터링이 실행되지 않았습니다.",
    "current_abnormal_pods": [],
    "new_issues": [],
    "persistent_issues": [],
    "resolved_issues": [],
    "stats": {},
    "timestamp": None
}
monitor_lock = threading.Lock()
auto_check_enabled = False
auto_check_interval_seconds = 60 * 5 # 5분마다 자동 점검

# Rust 모듈 로드 시도 (웹 서버에서도 동일하게 처리)
try:
    import rust_analyzer
    rust_enabled_module = rust_analyzer
    logging.info("웹 서버에서 Rust 모듈 'rust_analyzer' 로드 성공.")
except ImportError:
    logging.warning("웹 서버에서 Rust 모듈 'rust_analyzer'를 찾을 수 없습니다. Python 모드로 계속 진행합니다.")
    rust_enabled_module = None
except Exception as e:
    logging.warning(f"웹 서버에서 Rust 모듈 로드 중 예외 발생, Python 모드로 폴백: {e}")
    rust_enabled_module = None

def run_monitor_and_update_global():
    """
    모니터링을 실행하고 결과를 전역 변수에 업데이트합니다.
    Lock을 사용하여 동시성 문제를 방지합니다.
    """
    global latest_monitor_results
    with monitor_lock:
        logging.info("백그라운드 모니터링 실행 중...")
        try:
            results = main.run_monitor(rust_enabled_module)
            results["timestamp"] = datetime.now().isoformat()
            latest_monitor_results = results
            logging.info("백그라운드 모니터링 완료 및 결과 업데이트.")
        except Exception as e:
            logging.error(f"백그라운드 모니터링 중 오류 발생: {e}", exc_info=True)
            latest_monitor_results = {
                "success": False,
                "message": f"모니터링 실행 중 오류: {e}",
                "current_abnormal_pods": [],
                "new_issues": [],
                "persistent_issues": [],
                "resolved_issues": [],
                "stats": {},
                "timestamp": datetime.now().isoformat()
            }

def auto_check_loop():
    """자동 점검 루프."""
    global auto_check_enabled
    while True:
        if auto_check_enabled:
            run_monitor_and_update_global()
        time.sleep(auto_check_interval_seconds)

# 자동 점검 스레드 시작
auto_check_thread = threading.Thread(target=auto_check_loop, daemon=True)
auto_check_thread.start()
logging.info("자동 점검 스레드 시작.")

@app.route('/')
def index():
    """대시보드 HTML 페이지를 렌더링합니다."""
    return render_template('dashboard.html')

@app.route('/api/run_manual_check', methods=['POST'])
def api_run_manual_check():
    """수동으로 Pod 모니터링을 실행합니다."""
    logging.info("수동 모니터링 요청 수신.")
    # 별도의 스레드에서 실행하여 응답이 블록되지 않도록 함
    thread = threading.Thread(target=run_monitor_and_update_global)
    thread.start()
    return jsonify({"message": "Pod 모니터링이 백그라운드에서 시작되었습니다. 잠시 후 새로고침하세요."}), 202 # Accepted

@app.route('/api/get_latest_data')
def api_get_latest_data():
    """최신 모니터링 결과를 반환합니다."""
    with monitor_lock:
        return jsonify(latest_monitor_results)

@app.route('/api/toggle_auto_check', methods=['POST'])
def api_toggle_auto_check():
    """자동 점검을 토글합니다."""
    global auto_check_enabled
    data = request.get_json()
    enable = data.get('enable', None)

    if enable is None:
        auto_check_enabled = not auto_check_enabled
    else:
        auto_check_enabled = bool(enable)

    status = "활성화" if auto_check_enabled else "비활성화"
    logging.info(f"자동 점검 {status}.")
    return jsonify({"status": status, "auto_check_enabled": auto_check_enabled})

@app.route('/api/get_historical_data')
def api_get_historical_data():
    """과거 데이터를 읽어 시간별 추이 차트용 데이터를 제공합니다."""
    # 과거 7일치 데이터를 로드
    historical_data = []
    today = datetime.now().date()
    for i in range(7): # 지난 7일
        check_date = today - timedelta(days=i)
        filename = f"abnormal_pods_{check_date.strftime('%Y%m%d')}.txt"
        loaded_pods = main.load_abnormal_pods(filename)
        historical_data.append({
            "date": check_date.isoformat(),
            "count": len(loaded_pods),
            "pods": list(loaded_pods.values()) # Convert dict_values to a list
        })
    # 날짜 순으로 정렬 (가장 오래된 것부터)
    historical_data.sort(key=lambda x: x['date'])
    return jsonify(historical_data)

if __name__ == '__main__':
    logging.info("Flask 웹 서버 시작 중...")
    try:
        # 최초 1회 모니터링 실행하여 초기 데이터 채우기
        run_monitor_and_update_global()
        app.run(debug=True, host='0.0.0.0', port=5000)
    except Exception as e:
        logging.critical(f"Flask 서버 시작 중 치명적인 오류 발생: {e}", exc_info=True)
        sys.exit(1)
EOF
echo "✅ web_server.py 생성 완료."

echo "📄 dashboard.html 파일 생성 중..."
cat << 'EOF' > "$PROJECT_DIR/templates/dashboard.html"
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kubernetes Pod Monitor Dashboard</title>
    <!-- Tailwind CSS (CDN) -->
    <script src="https://cdn.tailwindcss.com"></script>
    <!-- Inter Font -->
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <!-- Plotly.js CDN -->
    <script src="https://cdn.plot.ly/plotly-2.15.1.min.js"></script>
    <style>
        body {
            font-family: 'Inter', sans-serif;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
            background-color: #f3f4f6;
            color: #1f2937;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 1rem;
        }
        .card {
            background-color: #ffffff;
            border-radius: 0.75rem; /* rounded-lg */
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06); /* shadow-md */
            padding: 1.5rem;
        }
        .tab-button {
            padding: 0.75rem 1.25rem;
            font-weight: 500;
            border-bottom: 3px solid transparent;
            transition: all 0.2s ease-in-out;
            border-radius: 0.5rem 0.5rem 0 0;
            margin-right: 0.5rem;
        }
        .tab-button.active {
            border-color: #3b82f6; /* blue-500 */
            color: #3b82f6; /* blue-500 */
            background-color: #eff6ff; /* blue-50 */
        }
        .tab-button:hover:not(.active) {
            background-color: #e5e7eb; /* gray-200 */
        }
        .table-header th {
            padding: 0.75rem;
            text-align: left;
            font-weight: 600;
            color: #4b5563;
            background-color: #f9fafb;
        }
        .table-body td {
            padding: 0.75rem;
            border-top: 1px solid #e5e7eb;
        }
        .status-badge {
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 9999px; /* full rounded */
            font-size: 0.75rem;
            font-weight: 600;
            color: #ffffff;
            text-transform: uppercase;
        }
        .status-badge.failed { background-color: #ef4444; } /* red-500 */
        .status-badge.pending { background-color: #f97316; } /* orange-500 */
        .status-badge.unknown { background-color: #6b7280; } /* gray-500 */
        .status-badge.running { background-color: #22c55e; } /* green-500 */
        .status-badge.succeeded { background-color: #3b82f6; } /* blue-500 */
        .status-badge.warning { background-color: #f59e0b; } /* amber-500 */

        .loading-overlay {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(255, 255, 255, 0.8);
            display: flex;
            justify-content: center;
            align-items: center;
            z-index: 1000;
            transition: opacity 0.3s ease;
            opacity: 0;
            pointer-events: none;
        }
        .loading-overlay.visible {
            opacity: 1;
            pointer-events: all;
        }
        .spinner {
            border: 4px solid rgba(0, 0, 0, 0.1);
            border-top: 4px solid #3b82f6;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    </style>
</head>
<body class="bg-gray-100 min-h-screen py-8">
    <div class="container">
        <h1 class="text-4xl font-bold text-center text-gray-800 mb-8">Kubernetes Pod Monitor</h1>

        <div class="flex justify-center mb-6 space-x-4">
            <button id="manualCheckBtn" class="bg-blue-600 hover:bg-blue-700 text-white font-semibold py-2 px-6 rounded-lg shadow-md transition duration-200">
                수동 점검 실행
            </button>
            <button id="autoCheckBtn" class="bg-gray-500 hover:bg-gray-600 text-white font-semibold py-2 px-6 rounded-lg shadow-md transition duration-200">
                자동 점검 (비활성화)
            </button>
        </div>

        <div class="loading-overlay" id="loadingOverlay">
            <div class="spinner"></div>
        </div>

        <div class="card mb-8">
            <div class="flex justify-between items-center mb-4">
                <h2 class="text-2xl font-semibold text-gray-700">실시간 통계</h2>
                <span class="text-sm text-gray-500" id="lastUpdated"></span>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-6">
                <div class="bg-blue-50 border border-blue-200 rounded-lg p-4 flex flex-col items-center justify-center">
                    <p class="text-sm font-medium text-gray-500">현재 비정상 Pod 수</p>
                    <p id="currentIssuesCount" class="text-4xl font-bold text-blue-600 mt-2">0</p>
                </div>
                <div class="bg-red-50 border border-red-200 rounded-lg p-4 flex flex-col items-center justify-center">
                    <p class="text-sm font-medium text-gray-500">오늘 신규 이슈</p>
                    <p id="newIssuesCount" class="text-4xl font-bold text-red-600 mt-2">0</p>
                </div>
                <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 flex flex-col items-center justify-center">
                    <p class="text-sm font-medium text-gray-500">오늘 지속 이슈</p>
                    <p id="persistentIssuesCount" class="text-4xl font-bold text-yellow-600 mt-2">0</p>
                </div>
                <div class="bg-green-50 border border-green-200 rounded-lg p-4 flex flex-col items-center justify-center">
                    <p class="text-sm font-medium text-gray-500">오늘 해결 이슈</p>
                    <p id="resolvedIssuesCount" class="text-4xl font-bold text-green-600 mt-2">0</p>
                </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div class="card">
                    <h3 class="text-xl font-semibold text-gray-700 mb-4">상태별 분포</h3>
                    <div id="statusChart" class="w-full" style="height: 300px;"></div>
                </div>
                <div class="card">
                    <h3 class="text-xl font-semibold text-gray-700 mb-4">클러스터별 분포</h3>
                    <div id="clusterChart" class="w-full" style="height: 300px;"></div>
                </div>
            </div>
        </div>

        <div class="card mb-8">
            <div class="flex border-b border-gray-200 mb-4">
                <button id="tabCurrent" class="tab-button active" onclick="showTab('current')">현재 비정상 Pods</button>
                <button id="tabDailyComparison" class="tab-button" onclick="showTab('dailyComparison')">일일 비교</button>
                <button id="tabHistoricalTrend" class="tab-button" onclick="showTab('historicalTrend')">시간별 추이</button>
            </div>

            <div id="tabCurrentContent" class="tab-content">
                <h3 class="text-xl font-semibold text-gray-700 mb-4">현재 감지된 비정상 Pod 목록</h3>
                <div class="overflow-x-auto rounded-lg shadow-md">
                    <table class="min-w-full bg-white">
                        <thead class="table-header">
                            <tr>
                                <th class="py-3 px-4">타임스탬프</th>
                                <th class="py-3 px-4">클러스터</th>
                                <th class="py-3 px-4">네임스페이스</th>
                                <th class="py-3 px-4">Pod 이름</th>
                                <th class="py-3 px-4">상태</th>
                                <th class="py-3 px-4">노드</th>
                                <th class="py-3 px-4">사유</th>
                            </tr>
                        </thead>
                        <tbody id="currentPodsTableBody" class="table-body">
                            <!-- Data will be inserted here -->
                            <tr><td colspan="7" class="text-center py-4 text-gray-500">데이터를 로드 중입니다...</td></tr>
                        </tbody>
                    </table>
                </div>
                <p id="noCurrentPods" class="text-center text-gray-500 py-4 hidden">현재 비정상 Pod가 없습니다.</p>
            </div>

            <div id="tabDailyComparisonContent" class="tab-content hidden">
                <h3 class="text-xl font-semibold text-gray-700 mb-4">일일 비교 (어제 vs 오늘)</h3>
                <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                    <div class="card">
                        <h4 class="text-lg font-semibold text-gray-700 mb-2">신규 이슈</h4>
                        <ul id="newIssuesList" class="list-disc pl-5 text-sm text-gray-600">
                            <li>데이터를 로드 중입니다...</li>
                        </ul>
                    </div>
                    <div class="card">
                        <h4 class="text-lg font-semibold text-gray-700 mb-2">지속 이슈</h4>
                        <ul id="persistentIssuesList" class="list-disc pl-5 text-sm text-gray-600">
                            <li>데이터를 로드 중입니다...</li>
                        </ul>
                    </div>
                    <div class="card">
                        <h4 class="text-lg font-semibold text-gray-700 mb-2">해결된 이슈</h4>
                        <ul id="resolvedIssuesList" class="list-disc pl-5 text-sm text-gray-600">
                            <li>데이터를 로드 중입니다...</li>
                        </ul>
                    </div>
                </div>
            </div>

            <div id="tabHistoricalTrendContent" class="tab-content hidden">
                <h3 class="text-xl font-semibold text-gray-700 mb-4">비정상 Pod 시간별 추이 (지난 7일)</h3>
                <div class="card">
                    <div id="historicalChart" class="w-full" style="height: 400px;"></div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const loadingOverlay = document.getElementById('loadingOverlay');
        const manualCheckBtn = document.getElementById('manualCheckBtn');
        const autoCheckBtn = document.getElementById('autoCheckBtn');

        let autoCheckIntervalId; // For clearing the interval

        function showLoading() {
            loadingOverlay.classList.add('visible');
        }

        function hideLoading() {
            loadingOverlay.classList.remove('visible');
        }

        function formatTimestamp(isoString) {
            if (!isoString) return '';
            const date = new Date(isoString);
            return date.toLocaleString('ko-KR', {
                year: 'numeric',
                month: '2-digit',
                day: '2-digit',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                hour12: false
            });
        }

        function getStatusBadgeClass(status) {
            switch (status.toLowerCase()) {
                case 'failed': return 'status-badge failed';
                case 'pending': return 'status-badge pending';
                case 'unknown': return 'status-badge unknown';
                case 'running': return 'status-badge running';
                case 'succeeded': return 'status-badge succeeded';
                default: return 'status-badge warning'; // General warning for unhandled statuses
            }
        }

        async function fetchDataAndUpdateUI() {
            showLoading();
            try {
                const response = await fetch('/api/get_latest_data');
                const data = await response.json();
                console.log("Latest Data:", data); // Debugging

                // Update real-time stats
                document.getElementById('currentIssuesCount').textContent = data.stats.current_issues_count || 0;
                document.getElementById('newIssuesCount').textContent = data.stats.new_issues_count || 0;
                document.getElementById('persistentIssuesCount').textContent = data.stats.persistent_issues_count || 0;
                document.getElementById('resolvedIssuesCount').textContent = data.stats.resolved_issues_count || 0;
                document.getElementById('lastUpdated').textContent = data.timestamp ? `마지막 업데이트: ${formatTimestamp(data.timestamp)}` : '업데이트 중...';

                // Update current abnormal pods table
                const currentPodsTableBody = document.getElementById('currentPodsTableBody');
                currentPodsTableBody.innerHTML = ''; // Clear previous data
                if (data.current_abnormal_pods && data.current_abnormal_pods.length > 0) {
                    document.getElementById('noCurrentPods').classList.add('hidden');
                    data.current_abnormal_pods.forEach(pod => {
                        const row = currentPodsTableBody.insertRow();
                        row.innerHTML = `
                            <td class="py-3 px-4">${formatTimestamp(pod.timestamp)}</td>
                            <td class="py-3 px-4">${pod.cluster}</td>
                            <td class="py-3 px-4">${pod.namespace}</td>
                            <td class="py-3 px-4">${pod.pod}</td>
                            <td class="py-3 px-4"><span class="${getStatusBadgeClass(pod.status)}">${pod.status}</span></td>
                            <td class="py-3 px-4">${pod.node}</td>
                            <td class="py-3 px-4 text-sm break-words max-w-xs">${pod.reasons}</td>
                        `;
                    });
                } else {
                    document.getElementById('noCurrentPods').classList.remove('hidden');
                    currentPodsTableBody.innerHTML = '<tr><td colspan="7" class="text-center py-4 text-gray-500">현재 비정상 Pod가 없습니다.</td></tr>';
                }

                // Update daily comparison lists
                const newIssuesList = document.getElementById('newIssuesList');
                const persistentIssuesList = document.getElementById('persistentIssuesList');
                const resolvedIssuesList = document.getElementById('resolvedIssuesList');

                newIssuesList.innerHTML = '';
                persistentIssuesList.innerHTML = '';
                resolvedIssuesList.innerHTML = '';

                if (data.new_issues && data.new_issues.length > 0) {
                    data.new_issues.forEach(issue => {
                        newIssuesList.innerHTML += `<li>${issue.cluster}/${issue.namespace}/${issue.pod} - ${issue.status} (${issue.reasons})</li>`;
                    });
                } else {
                    newIssuesList.innerHTML = '<li>신규 이슈가 없습니다.</li>';
                }

                if (data.persistent_issues && data.persistent_issues.length > 0) {
                    data.persistent_issues.forEach(issue => {
                        persistentIssuesList.innerHTML += `<li>${issue.cluster}/${issue.namespace}/${issue.pod} - ${issue.status} (${issue.reasons})</li>`;
                    });
                } else {
                    persistentIssuesList.innerHTML = '<li>지속 이슈가 없습니다.</li>';
                }

                if (data.resolved_issues && data.resolved_issues.length > 0) {
                    data.resolved_issues.forEach(issue => {
                        resolvedIssuesList.innerHTML += `<li>${issue.cluster}/${issue.namespace}/${issue.pod} - ${issue.status} (해결됨)</li>`;
                    });
                } else {
                    resolvedIssuesList.innerHTML = '<li>해결된 이슈가 없습니다.</li>';
                }

                // Render charts
                renderStatusChart(data.stats.status_distribution);
                renderClusterChart(data.stats.cluster_distribution);
                await renderHistoricalChart();

            } catch (error) {
                console.error("Error fetching data:", error);
                document.getElementById('lastUpdated').textContent = `데이터 로드 실패: ${error.message}`;
                // Optionally update UI to show error state
            } finally {
                hideLoading();
            }
        }

        function renderStatusChart(data) {
            const labels = Object.keys(data);
            const values = Object.values(data);
            const colors = {
                'Failed': '#ef4444',
                'Pending': '#f97316',
                'Unknown': '#6b7280',
                'Running': '#22c55e',
                'Succeeded': '#3b82f6'
            };
            const pieColors = labels.map(label => colors[label] || '#f59e0b'); // Default amber

            const chartData = [{
                labels: labels,
                values: values,
                type: 'pie',
                marker: {
                    colors: pieColors
                },
                hoverinfo: 'label+percent',
                textinfo: 'value',
                pull: [0.05, 0, 0, 0, 0],
                hole: .4
            }];

            const layout = {
                margin: {t: 0, b: 0, l: 0, r: 0},
                showlegend: true,
                legend: {
                    orientation: "h",
                    x: 0, y: 1.1
                },
                plot_bgcolor: '#ffffff',
                paper_bgcolor: '#ffffff'
            };
            Plotly.newPlot('statusChart', chartData, layout, {responsive: true});
        }

        function renderClusterChart(data) {
            const labels = Object.keys(data);
            const values = Object.values(data);

            const chartData = [{
                x: labels,
                y: values,
                type: 'bar',
                marker: {
                    color: '#3b82f6' // blue-500
                }
            }];

            const layout = {
                xaxis: { title: '클러스터', automargin: true },
                yaxis: { title: '비정상 Pod 수', automargin: true },
                margin: {t: 20, b: 60, l: 40, r: 20},
                plot_bgcolor: '#ffffff',
                paper_bgcolor: '#ffffff'
            };
            Plotly.newPlot('clusterChart', chartData, layout, {responsive: true});
        }

        async function renderHistoricalChart() {
            try {
                const response = await fetch('/api/get_historical_data');
                const data = await response.json();

                const dates = data.map(item => item.date);
                const counts = data.map(item => item.count);

                const trace = {
                    x: dates,
                    y: counts,
                    mode: 'lines+markers',
                    name: '비정상 Pod 수',
                    line: {
                        color: '#10b981', // emerald-500
                        width: 3
                    },
                    marker: {
                        size: 8,
                        color: '#10b981',
                        line: {
                            color: '#ffffff',
                            width: 1
                        }
                    }
                };

                const layout = {
                    xaxis: { title: '날짜', type: 'category', automargin: true },
                    yaxis: { title: '비정상 Pod 수', rangemode: 'tozero', automargin: true },
                    margin: {t: 20, b: 60, l: 40, r: 20},
                    plot_bgcolor: '#ffffff',
                    paper_bgcolor: '#ffffff',
                    hovermode: 'x unified'
                };

                Plotly.newPlot('historicalChart', [trace], layout, {responsive: true});

            } catch (error) {
                console.error("Error fetching historical data:", error);
            }
        }

        function showTab(tabId) {
            // Hide all tab contents
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.add('hidden');
            });
            // Deactivate all tab buttons
            document.querySelectorAll('.tab-button').forEach(btn => {
                btn.classList.remove('active');
            });

            // Show selected tab content
            document.getElementById(`tab${tabId.charAt(0).toUpperCase() + tabId.slice(1)}Content`).classList.remove('hidden');
            // Activate selected tab button
            document.getElementById(`tab${tabId.charAt(0).toUpperCase() + tabId.slice(1)}`).classList.add('active');

            // Re-render charts when their tab becomes visible
            if (tabId === 'historicalTrend') {
                renderHistoricalChart(); // Ensure chart re-renders correctly on tab switch
            }
        }


        // Event Listeners
        manualCheckBtn.addEventListener('click', async () => {
            showLoading();
            try {
                const response = await fetch('/api/run_manual_check', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' }
                });
                if (response.status === 202) {
                    alert("Pod 모니터링이 백그라운드에서 시작되었습니다. 잠시 후 데이터가 업데이트됩니다.");
                } else {
                    const errorData = await response.json();
                    alert(`오류: ${errorData.message}`);
                }
            } catch (error) {
                console.error("Manual check request failed:", error);
                alert(`점검 요청 중 오류가 발생했습니다: ${error.message}`);
            } finally {
                // Fetch new data after a short delay to allow server to process
                setTimeout(fetchDataAndUpdateUI, 3000); // Wait 3 seconds
            }
        });

        autoCheckBtn.addEventListener('click', async () => {
            try {
                const response = await fetch('/api/toggle_auto_check', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' }
                });
                const data = await response.json();
                if (data.auto_check_enabled) {
                    autoCheckBtn.classList.remove('bg-gray-500', 'hover:bg-gray-600');
                    autoCheckBtn.classList.add('bg-green-600', 'hover:bg-green-700');
                    autoCheckBtn.textContent = '자동 점검 (활성화)';
                    // Start polling if auto-check is enabled
                    // Clear any existing interval first to prevent duplicates
                    if (autoCheckIntervalId) clearInterval(autoCheckIntervalId);
                    autoCheckIntervalId = setInterval(fetchDataAndUpdateUI, 5 * 60 * 1000); // 5 minutes
                    alert("자동 점검이 활성화되었습니다 (5분마다 업데이트).");
                } else {
                    autoCheckBtn.classList.remove('bg-green-600', 'hover:bg-green-700');
                    autoCheckBtn.classList.add('bg-gray-500', 'hover:bg-gray-600');
                    autoCheckBtn.textContent = '자동 점검 (비활성화)';
                    // Stop polling if auto-check is disabled
                    if (autoCheckIntervalId) {
                        clearInterval(autoCheckIntervalId);
                        autoCheckIntervalId = null;
                    }
                    alert("자동 점검이 비활성화되었습니다.");
                }
            } catch (error) {
                console.error("Auto check toggle failed:", error);
                alert(`자동 점검 토글 중 오류가 발생했습니다: ${error.message}`);
            }
        });

        // Initial data load when page loads
        document.addEventListener('DOMContentLoaded', () => {
            fetchDataAndUpdateUI();
            // Check initial auto-check status from server (optional, or assume initial state)
            // For simplicity, we assume auto-check starts disabled and user enables it.
            // If the server retained state, an initial fetch to /api/toggle_auto_check without payload could retrieve it.
        });

        // Responsive Plotly charts on window resize
        window.addEventListener('resize', function() {
            Plotly.relayout('statusChart', { autosize: true });
            Plotly.relayout('clusterChart', { autosize: true });
            Plotly.relayout('historicalChart', { autosize: true });
        });

        // Custom alert function to replace window.alert
        function alert(message) {
            const existingAlert = document.getElementById('custom-alert');
            if (existingAlert) existingAlert.remove();

            const alertDiv = document.createElement('div');
            alertDiv.id = 'custom-alert';
            alertDiv.className = 'fixed top-4 right-4 bg-blue-600 text-white px-6 py-3 rounded-lg shadow-xl z-50 transform translate-x-full transition-transform duration-300 ease-out flex items-center space-x-2';
            alertDiv.innerHTML = `
                <span>${message}</span>
                <button class="text-white text-lg font-bold ml-auto" onclick="document.getElementById('custom-alert').remove()">&times;</button>
            `;
            document.body.appendChild(alertDiv);

            // Animate in
            setTimeout(() => {
                alertDiv.style.transform = 'translateX(0)';
            }, 50);

            // Animate out and remove after 5 seconds
            setTimeout(() => {
                alertDiv.style.transform = 'translateX(120%)';
                alertDiv.addEventListener('transitionend', () => alertDiv.remove(), { once: true });
            }, 5000);
        }

        // Override window.alert to use custom alert
        window.alert = alert;

    </script>
</body>
</html>
EOF
echo "✅ dashboard.html 생성 완료."

echo "🦀 Cargo.toml 파일 생성 중..."
cat << EOF > "$PROJECT_DIR/rust_analyzer/Cargo.toml"
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
echo "✅ Cargo.toml 생성 완료."

echo "🦀 lib.rs 파일 생성 중..."
cat << 'EOF' > "$PROJECT_DIR/rust_analyzer/src/lib.rs"
// rust_analyzer/src/lib.rs: PyO3 바인딩을 위한 Rust 모듈
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use chrono::{DateTime, Utc};

// Pod 데이터를 표현하기 위한 Rust 구조체
// Python 딕셔너리와 JSON 직렬화/역직렬화를 위해 Serialize, Deserialize를 사용합니다.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PodData {
    timestamp: String, // ISO format string
    cluster: String,
    namespace: String,
    pod: String,
    status: String,
    node: String,
    reasons: String,
}

/// Python에서 호출될 Rust 함수.
/// JSON 문자열 형태의 Pod 데이터 리스트를 받아 처리합니다.
/// 현재는 받은 데이터를 역직렬화하고 간단히 필터링 후 직렬화하여 반환하는 예시입니다.
#[pyfunction]
fn analyze_pod_data_rust(py: Python, json_data: String) -> PyResult<Py<PyList>> {
    // 1. JSON 문자열을 Rust의 Vec<PodData>로 역직렬화합니다.
    let pods: Vec<PodData> = serde_json::from_str(&json_data)
        .map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("JSON 역직렬화 오류: {}", e)))?;

    let mut filtered_pods = Vec::new();
    // 예시: 'Failed' 상태의 Pod만 필터링합니다.
    for pod in pods {
        if pod.status == "Failed" {
            filtered_pods.push(pod);
        }
    }

    // 2. 필터링된 Pod 데이터를 Python 리스트로 변환합니다.
    let py_list = PyList::empty(py);
    for pod in filtered_pods {
        let dict = PyDict::new(py);
        dict.set_item("timestamp", pod.timestamp)?;
        dict.set_item("cluster", pod.cluster)?;
        dict.set_item("namespace", pod.namespace)?;
        dict.set_item("pod", pod.pod)?;
        dict.set_item("status", pod.status)?;
        dict.set_item("node", pod.node)?;
        dict.set_item("reasons", pod.reasons)?;
        py_list.append(dict)?;
    }

    Ok(py_list.into())
}

/// PyO3 모듈 정의. Python에서 'import rust_analyzer'로 이 모듈을 가져올 수 있습니다.
#[pymodule]
fn rust_analyzer(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(analyze_pod_data_rust, m)?)?;
    Ok(())
}
EOF
echo "✅ lib.rs 생성 완료."

echo "🛠️ build.sh 파일 생성 중..."
cat << 'EOF' > "$PROJECT_DIR/build.sh"
#!/bin/bash

# 사용자에게서 미래라는 이름을 받은 날짜입니다.
# 2025-07-14

# 현재 사용자의 이름이 구원임을 알려줍니다.

set -e # Exit immediately if a command exits with a non-zero status.

PROJECT_ROOT=$(dirname "$0") # build.sh가 위치한 디렉터리
VENV_DIR="$PROJECT_ROOT/venv"
REQUIREMENTS_FILE="$PROJECT_ROOT/requirements.txt"
RUST_ANALYZE_DIR="$PROJECT_ROOT/rust_analyzer"

echo "⚙️ 빌드 프로세스를 시작합니다..."

# 1. Python 가상환경 생성 및 활성화
echo "🐍 Python 가상환경 생성 및 활성화 중..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    echo "✅ 가상환경 '$VENV_DIR' 생성 완료."
else
    echo "ℹ️ 가상환경 '$VENV_DIR'이 이미 존재합니다."
fi

# 가상환경 활성화 (Bash/Zsh)
# 스크립트 내에서 활성화해도 외부 쉘에 영향을 주지 않으므로, 직접 호출하여 사용합니다.
source "$VENV_DIR/bin/activate"
echo "✅ 가상환경 활성화 완료."

# 2. pip 업그레이드
echo "⬆️ pip 업그레이드 중..."
pip install --upgrade pip setuptools wheel > /dev/null 2>&1
echo "✅ pip 업그레이드 완료."

# 3. Python 의존성 설치
echo "📦 Python 의존성 설치 중..."
if [ -f "$REQUIREMENTS_FILE" ]; then
    pip install -r "$REQUIREMENTS_FILE"
    echo "✅ Python 의존성 설치 완료."
else
    echo "⚠️ requirements.txt 파일이 없습니다: $REQUIREMENTS_FILE. Python 의존성 설치를 건너뜀."
fi

# 4. Rust 설치 확인 및 조건부 빌드
echo "🦀 Rust 모듈 빌드를 시도합니다..."
if command -v rustc &> /dev/null && command -v cargo &> /dev/null; then
    echo "✅ Rust (rustc, cargo)가 설치되어 있습니다."
    echo "🔨 maturin을 사용하여 Rust 모듈 빌드 중..."
    # maturin develop은 Rust 모듈을 빌드하고 가상 환경에 설치합니다.
    # --release 플래그를 사용하여 최적화된 빌드를 생성합니다.
    (cd "$RUST_ANALYZE_DIR" && maturin develop --release --quiet)
    if [ $? -eq 0 ]; then
        echo "✅ Rust 모듈 'rust_analyzer' 빌드 및 설치 성공."
    else
        echo "❌ Rust 모듈 빌드에 실패했습니다. Python 모드로 폴백합니다."
        echo "ℹ️ 오류 메시지 위를 확인하여 원인을 파악하세요."
    fi
else
    echo "⚠️ Rust (rustc, cargo)가 설치되어 있지 않습니다. Rust 모듈 빌드를 건너뛰고 Python 모드로 실행합니다."
    echo "   Rust를 설치하려면 https://rustup.rs/ 를 방문하세요."
fi

# 5. 실행 환경 점검 (선택적)
echo "🔍 실행 환경 점검 중..."
if command -v kubectl &> /dev/null; then
    echo "✅ kubectl이 설치되어 있습니다."
else
    echo "⚠️ kubectl이 설치되어 있지 않습니다. Kubernetes 클러스터에 접속하지 못할 수 있습니다."
fi

if [ -f "$HOME/.kube/config" ]; then
    echo "✅ kubeconfig 파일 ($HOME/.kube/config)이 존재합니다."
else
    echo "⚠️ kubeconfig 파일 ($HOME/.kube/config)을 찾을 수 없습니다. Kubernetes 클러스터에 접속하지 못할 수 있습니다."
    echo "   Kubernetes 클러스터에 연결되어 있는지 확인해주세요."
fi

echo "🎉 빌드 프로세스 완료."
echo "----------------------------------------------------"
echo "다음 단계:"
echo "1. 가상환경 활성화: source $VENV_DIR/bin/activate"
echo "2. CLI 테스트: python $PROJECT_ROOT/main.py"
echo "3. 웹 서버 테스트: python $PROJECT_ROOT/web_server.py"
echo "   (웹 서버 실행 후 http://localhost:5000 에 접속하여 대시보드를 확인하세요)"
echo "----------------------------------------------------"
EOF
chmod +x "$PROJECT_DIR/build.sh"
echo "✅ build.sh 생성 완료."

echo "📄 README.md 파일 생성 중..."
cat << 'EOF' > "$PROJECT_DIR/README.md"
# Kubernetes Pod Monitor

이 프로젝트는 Kubernetes Pod의 비정상 상태를 모니터링하고, 웹 대시보드를 통해 시각화하는 시스템입니다. Python으로 주요 로직이 구현되었으며, 성능이 중요한 부분에서는 선택적으로 Rust 모듈을 사용할 수 있도록 설계되었습니다.

## 🎯 주요 기능

-   **CLI 모드**: 일회성으로 Kubernetes Pod 상태를 점검하고 결과를 터미널에 출력합니다.
-   **웹 모드**: Flask 기반의 웹 서버와 Bootstrap 5, Plotly.js를 사용한 대시보드를 제공하여 실시간 통계, 일일 비교 (신규/지속/해결 이슈), 시간별 추이 차트를 제공합니다.
-   **데이터 저장**: `abnormal_pods_YYYYMMDD.txt` 형식의 파일에 비정상 Pod 데이터를 저장합니다.
-   **일일 비교**: 어제와 오늘 파일을 비교하여 신규, 지속, 해결된 이슈를 추적합니다.
-   **Rust 가속화 (선택 사항)**: Rust로 구현된 모듈을 통해 특정 데이터 처리 작업을 가속화할 수 있습니다. Rust가 설치되어 있지 않아도 Python 모드로 자동 폴백됩니다.

## 🚀 설치 및 실행 가이드

프로젝트를 설정하고 실행하는 가장 쉬운 방법은 제공된 `create_project.sh` 스크립트를 사용하는 것입니다.

### 1. 프로젝트 생성 스크립트 다운로드 및 실행

터미널에서 다음 명령을 실행합니다:

```bash
# create_k8s_monitor.sh 스크립트 다운로드
curl -O [https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/create_k8s_monitor.sh](https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/create_k8s_monitor.sh)
# 또는 직접 파일을 생성합니다 (이 스크립트 내용을 복사하여 create_k8s_monitor.sh로 저장)

# 실행 권한 부여
chmod +x create_k8s_monitor.sh

# 스크립트 실행
./create_k8s_monitor.sh

이 스크립트는 k8s-pod-monitor/ 디렉터리를 생성하고, 그 안에 모든 필요한 파일 (Python 소스, Rust 소스, HTML 템플릿, 빌드 스크립트, 의존성 파일 등)을 자동으로 생성합니다.
2. 프로젝트 빌드
create_project.sh 스크립트 실행 후, 생성된 k8s-pod-monitor 디렉터리로 이동하여 build.sh 스크립트를 실행합니다. 이 스크립트는 Python 가상환경을 설정하고, 필요한 의존성을 설치하며, Rust가 설치되어 있다면 Rust 모듈을 빌드합니다.
cd k8s-pod-monitor
./build.sh

참고: build.sh 스크립트는 Rust가 설치되어 있지 않아도 오류 없이 Python 모드로 계속 진행하도록 설계되었습니다.
3. Kubernetes 연결 설정 확인
시스템이 Kubernetes 클러스터에 연결될 수 있는지 확인해야 합니다. 일반적으로 ~/.kube/config 파일이 올바르게 설정되어 있어야 합니다. kubectl get pods 명령으로 클러스터 연결을 테스트할 수 있습니다.
kubectl get pods

4. CLI 모드 테스트
Python 가상환경을 활성화하고 main.py를 실행하여 CLI 모드를 테스트합니다:
# 가상환경 활성화 (build.sh 실행 후 출력된 경로를 참고)
source venv/bin/activate

# CLI 모니터링 실행
python main.py

명령줄에 현재 비정상 Pod 정보와 일일 비교 결과가 출력될 것입니다.
5. 웹 서버 모드 테스트
가상환경이 활성화된 상태에서 web_server.py를 실행하여 웹 대시보드를 시작합니다:
# 가상환경이 활성화되어 있는지 확인
source venv/bin/activate # 필요한 경우 다시 활성화

# 웹 서버 실행
python web_server.py

웹 서버가 시작되면 브라우저를 열고 http://localhost:5000으로 접속하여 대시보드를 확인합니다.
🛠️ 개발 환경 및 의존성
Python 의존성 (requirements.txt)
kubernetes==28.1.0
requests==2.31.0
flask==2.3.2
flask-cors==4.0.0
plotly==5.15.0
maturin==1.2.3

Rust 의존성 (rust_analyzer/Cargo.toml)
[dependencies]
pyo3 = { version = "0.20", features = ["extension-module"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
chrono = { version = "0.4", features = ["serde"] }

📝 파일 구조
k8s-pod-monitor/
├── main.py                  # CLI 모니터링 및 로깅 로직
├── web_server.py            # Flask 웹서버 및 API 엔드포인트
├── create_project.sh        # 전체 프로젝트 생성 스크립트
├── build.sh                 # 빌드 스크립트 (가상환경, 의존성, Rust 모듈 빌드)
├── requirements.txt         # Python 의존성 목록
├── templates/               # Flask 템플릿 (HTML)
│   └── dashboard.html       # 웹 대시보드 UI
├── rust_analyzer/           # Rust 모듈 디렉터리
│   ├── Cargo.toml          # Rust 패키지 설정
│   └── src/lib.rs          # PyO3 바인딩 Rust 소스 코드
├── data/                    # 모니터링 로그 파일 저장 (abnormal_pods_YYYYMMDD.txt)
└── README.md                # 이 문서

⚠️ 문제 해결
 * kubeconfig 오류: kubeconfig 로드 오류 메시지가 나타나면, ~/.kube/config 파일이 유효하며 현재 Kubernetes 클러스터에 접근 권한이 있는지 확인하세요.
 * Rust 빌드 실패: build.sh 실행 시 Rust 모듈 빌드에 실패하더라도 Python 모드로 계속 실행되므로 기능 자체는 사용할 수 있습니다. Rust 가속화를 원한다면 Rustup을 통해 Rust를 설치하고 다시 build.sh를 실행하세요.
 * 웹 서버 접속 불가: web_server.py 실행 후 http://localhost:5000에 접속할 수 없다면, 다른 프로그램이 5000번 포트를 사용 중일 수 있습니다. lsof -i :5000 (macOS/Linux) 또는 netstat -ano | findstr :5000 (Windows) 명령으로 포트 사용 여부를 확인하고, 필요한 경우 web_server.py에서 포트 번호를 변경할 수 있습니다.
 * 권한 문제: 파일 쓰기/읽기 오류가 발생하면, k8s-pod-monitor 디렉터리에 대한 현재 사용자 쓰기 권한을 확인하세요.
EOF
echo "✅ README.md 생성 완료."
echo "🎉 모든 파일이 성공적으로 생성되었습니다!"
echo "----------------------------------------------------"
echo "다음 단계를 실행해주세요:"
echo "1. 프로젝트 디렉터리로 이동: cd $PROJECT_DIR"
echo "2. 빌드 스크립트 실행: ./build.sh"
echo "3. CLI 또는 웹 서버를 실행하여 기능을 확인: (build.sh 출력 참고)"
echo "----------------------------------------------------"

