#!/bin/bash

# ==============================================================================
# Kubernetes Pod Monitor 생성 스크립트 (오류 방지 및 완전 자동화)
# 요청 목표: 오류 없이 즉시 실행 가능한 완전한 배포 소스 제공
# 제작자: 미래
# ==============================================================================

# 스크립트 실행 중 오류가 발생하면 즉시 중단합니다. (안전장치)
set -e

# --- 1. 기본 프로젝트 설정 및 디렉터리 생성 ---
PROJECT_NAME="k8s-pod-monitor"
RUST_CRATE_NAME="rust_analyzer"

echo "✅ [1/9] 프로젝트 생성을 시작합니다: $PROJECT_NAME"
# 기존 디렉터리가 있다면 안전하게 삭제합니다.
if [ -d "$PROJECT_NAME" ]; then
    echo "⚠️  기존 '$PROJECT_NAME' 디렉터리를 삭제합니다."
    rm -rf "$PROJECT_NAME"
fi
mkdir -p "$PROJECT_NAME/templates"
mkdir -p "$PROJECT_NAME/$RUST_CRATE_NAME/src"
cd "$PROJECT_NAME"

# --- 2. README.md 생성 ---
echo "✅ [2/9] 상세 가이드(README.md) 파일을 생성합니다..."
cat << 'EOF' > README.md
# Kubernetes Pod Monitor

이 프로젝트는 Kubernetes 클러스터의 Pod 상태를 모니터링하고, 비정상 상태의 Pod를 추적하여 웹 대시보드에 시각화하는 도구입니다. Python을 메인으로 사용하며, 선택적으로 Rust 모듈을 통해 데이터 처리 성능을 가속화할 수 있습니다.

## 주요 기능

- **CLI 모드**: 터미널에서 즉시 클러스터 상태를 점검하고 결과를 파일로 저장합니다.
- **웹 대시보드 모드**: Flask 기반의 웹 UI를 통해 실시간 현황, 일일 비교, 시계열 차트 등을 제공합니다.
- **하이브리드 아키텍처**: Rust가 설치된 환경에서는 자동으로 Rust 모듈을 빌드하여 성능을 향상시키고, 그렇지 않은 환경에서는 순수 Python 모드로 안전하게 동작합니다.
- **파일 기반 데이터 저장**: 별도의 DB 없이 `abnormal_pods_YYYYMMDD.txt` 형식으로 일일 데이터를 저장하고 분석합니다.

## 설치 및 실행 방법

### 1. 프로젝트 생성

이 프로젝트는 `create_k8s_monitor.sh` 스크립트를 통해 생성되었습니다. 이미 생성된 상태이므로 이 단계는 건너뜁니다.

### 2. 의존성 설치 및 빌드

프로젝트 디렉터리에서 아래의 빌드 스크립트를 실행합니다. 이 스크립트는 다음 작업을 자동으로 수행합니다.

- Python 가상환경(`venv`) 활성화
- `requirements.txt`에 명시된 모든 Python 라이브러리 설치
- Rust/Cargo 설치 여부 확인 후, 설치된 경우 Rust 모듈 컴파일 및 설치
- Rust가 없는 경우, 경고 메시지를 출력하고 안전하게 Python 모드로 진행

```bash
./build.sh

3. CLI 모드 실행
터미널에서 클러스터의 Pod 상태를 즉시 점검하고 결과를 저장합니다.
# 가상환경 활성화
source venv/bin/activate

# CLI 모니터 실행
python main.py

4. 웹 대시보드 실행
실시간 모니터링 대시보드를 실행합니다.
# 가상환경 활성화 (이미 활성화했다면 생략)
source venv/bin/activate

# 웹 서버 실행
python web_server.py

서버가 실행되면 웹 브라우저에서 http://127.0.0.1:5000 주소로 접속하여 대시보드를 확인할 수 있습니다.
프로젝트 구조
k8s-pod-monitor/
├── main.py                  # CLI 모니터링 로직
├── web_server.py            # Flask 웹서버 로직
├── create_project.sh        # (생성용) 전체 프로젝트 생성 스크립트
├── build.sh                 # 의존성 설치 및 빌드 스크립트
├── requirements.txt         # Python 의존성 버전 명시
├── pyproject.toml           # Rust 빌드 설정 (Maturin)
├── templates/dashboard.html # 웹 대시보드 UI
├── rust_analyzer/           # Rust 소스 코드 디렉터리
│   ├── Cargo.toml          # Rust 의존성 설정
│   └── src/lib.rs          # Rust 데이터 분석 및 PyO3 바인딩 로직
└── README.md                # 본 파일

오류 처리 및 안정성
이 프로젝트는 다양한 오류 상황에 대응하도록 설계되었습니다.
 * Kubeconfig 부재: ~/.kube/config 파일이 없거나 클러스터에 접속할 수 없는 경우, 적절한 에러 메시지를 출력합니다.
 * Rust 빌드 실패: Rust가 없거나 빌드에 실패해도 프로그램은 순수 Python 모드로 정상 실행됩니다.
 * 파일 I/O 오류: 데이터 파일 읽기/쓰기 시 발생할 수 있는 권한 문제나 기타 예외를 처리합니다.
 * API 타임아웃: Kubernetes API 서버와의 통신에서 발생할 수 있는 타임아웃을 처리합니다.
   EOF
--- 3. Python 의존성 파일 (requirements.txt) 생성 ---
echo "✅ [3/9] Python 의존성(requirements.txt) 파일을 생성합니다..."
cat << 'EOF' > requirements.txt
이 파일은 build.sh 스크립트에 의해 자동으로 설치됩니다.
Python 3.8+ 호환성 및 안정성이 검증된 버전 목록입니다.
kubernetes==28.1.0
requests==2.31.0
flask==2.3.2
flask-cors==4.0.0
plotly==5.15.0
maturin==1.2.3
파일 락 처리를 위한 의존성
filelock==3.12.2
EOF
--- 4. Rust 빌드 설정 파일 (pyproject.toml, Cargo.toml) 생성 ---
echo "✅ [4/9] Rust 빌드 설정 파일들을 생성합니다..."
Maturin 설정
cat << EOF > pyproject.toml
[build-system]
requires = ["maturin>=1.2.3,<2.0"]
build-backend = "maturin"
[project]
name = "$RUST_CRATE_NAME"
requires-python = ">=3.8"
classifiers = [
"Programming Language :: Rust",
"Programming Language :: Python :: 3",
]
EOF
Cargo 설정
cat << 'EOF' > "$RUST_CRATE_NAME/Cargo.toml"
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
--- 5. 빌드 스크립트 (build.sh) 생성 ---
echo "✅ [5/9] 안정적인 빌드 스크립트(build.sh)를 생성합니다..."
cat << 'EOF' > build.sh
#!/bin/bash
set -e
echo "--- Kubernetes Pod Monitor 빌드 시작 ---"
1. Python 가상환경 확인 및 활성화
if [ ! -d "venv" ]; then
echo "🐍 Python 가상환경(venv)을 생성합니다..."
python3 -m venv venv
fi
echo "🐍 가상환경을 활성화합니다..."
source venv/bin/activate
2. Python 의존성 설치
echo "📦 requirements.txt에 명시된 Python 라이브러리를 설치합니다..."
pip install --upgrade pip > /dev/null
pip install -r requirements.txt
3. Rust 설치 확인 및 조건부 빌드
if ! command -v cargo &> /dev/null
then
echo "⚠️  경고: Rust/Cargo가 설치되어 있지 않습니다. Rust 모듈 빌드를 건너뜁니다."
echo "프로그램은 순수 Python 모드로 실행됩니다."
else
echo "🦀 Rust가 감지되었습니다. Rust 모듈 빌드를 시도합니다..."
# maturin develop: Rust 코드를 컴파일하여 현재 venv에 설치
if maturin develop; then
echo "✅ Rust 모듈 빌드 및 설치 성공!"
else
echo "❌ 에러: Rust 모듈 빌드에 실패했습니다."
echo "순수 Python 모드로 계속 진행합니다."
fi
fi
echo "--- 빌드 완료 ---"
echo "CLI 실행: python main.py"
echo "웹 서버 실행: python web_server.py (http://127.0.0.1:5000)"
EOF
chmod +x build.sh
--- 6. Rust 소스 코드 (src/lib.rs) 생성 ---
echo "✅ [6/9] Rust 분석 모듈(src/lib.rs) 소스 코드를 생성합니다..."
cat << 'EOF' > "$RUST_CRATE_NAME/src/lib.rs"
use pyo3::prelude::*;
use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
// Python에서 전달받을 Pod 데이터 구조체
#[derive(Deserialize, Debug)]
struct PodInput {
cluster: String,
namespace: String,
pod_name: String,
status: String,
node: String,
reasons: Vec<String>,
}
// Python으로 반환할 분석 결과 구조체
#[derive(Serialize, Debug)]
struct AnalysisOutput {
timestamp: String,
cluster: String,
namespace: String,
pod_name: String,
status: String,
node: String,
reason_str: String,
}
/// Pod 목록을 분석하여 비정상 Pod 정보를 문자열 목록으로 반환합니다.
/// 이 함수는 Python에서 호출됩니다.
#[pyfunction]
fn analyze_pods_rust(pods_json: String) -> PyResult<Vec<String>> {
// JSON 문자열을 Rust 구조체 벡터로 역직렬화합니다.
let pods: Vec<PodInput> = serde_json::from_str(&pods_json)
.map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("JSON parsing failed: {}", e)))?;
let now: DateTime<Utc> = Utc::now();
let timestamp_str = now.format("%Y-%m-%d %H:%M:%S").to_string();
let results: Vec<String> = pods.into_iter()
.map(|pod| {
// 분석 결과를 지정된 포맷의 문자열로 만듭니다.
format!(
"{} | {} | {} | {} | {} | {} | {}",
&timestamp_str,
pod.cluster,
pod.namespace,
pod.pod_name,
pod.status,
pod.node,
pod.reasons.join(", ")
)
})
.collect();
Ok(results)
}
/// Python 모듈을 정의하고, analyze_pods_rust 함수를 노출시킵니다.
#[pymodule]
fn rust_analyzer(_py: Python, m: &PyModule) -> PyResult<()> {
m.add_function(wrap_pyfunction!(analyze_pods_rust, m)?)?;
Ok(())
}
EOF
--- 7. CLI 애플리케이션 (main.py) 생성 ---
echo "✅ [7/9] CLI 애플리케이션(main.py)을 생성합니다..."
cat << 'EOF' > main.py
import os
import json
from pathlib import Path
from datetime import datetime, timedelta
import logging
from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException
import filelock
로깅 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
--- Rust 모듈 로드 시도 및 폴백 ---
try:
import rust_analyzer
RUST_ENABLED = True
logging.info("🦀 Rust 모듈 로드 성공! 고속 모드로 실행합니다.")
except ImportError:
RUST_ENABLED = False
logging.warning("⚠️ Rust 모듈을 찾을 수 없습니다. 순수 Python 모드로 실행합니다.")
전역 설정
DATA_DIR = Path("data")
ABNORMAL_STATUSES = ['Pending', 'Failed', 'Unknown', 'CrashLoopBackOff', 'ImagePullBackOff', 'Error', 'Evicted']
def ensure_dir(path: Path):
"""디렉터리가 없으면 생성합니다."""
path.mkdir(parents=True, exist_ok=True)
def get_abnormal_pods(context_name: str, core_v1):
"""클러스터에서 비정상 상태의 Pod 목록을 가져옵니다."""
abnormal_pods_list = []
try:
ret = core_v1.list_pod_for_all_namespaces(watch=False, timeout_seconds=60)
for i in ret.items:
pod_status = i.status.phase
reasons = []
# 컨테이너 상태를 더 자세히 확인하여 CrashLoopBackOff 등 탐지
if i.status.container_statuses:
for c_status in i.status.container_statuses:
if c_status.state.waiting and c_status.state.waiting.reason:
pod_status = c_status.state.waiting.reason
reasons.append(f"Waiting: {pod_status}")
elif c_status.state.terminated and c_status.state.terminated.reason:
pod_status = c_status.state.terminated.reason
reasons.append(f"Terminated: {pod_status}")
if pod_status in ABNORMAL_STATUSES:
if not reasons:
reasons.append(i.status.message or "No specific message")
pod_data = {
"cluster": context_name,
"namespace": i.metadata.namespace,
"pod_name": i.metadata.name,
"status": pod_status,
"node": i.spec.node_name or "N/A",
"reasons": reasons,
}
abnormal_pods_list.append(pod_data)
except ApiException as e:
logging.error(f"'{context_name}' 클러스터에서 API 에러 발생: {e}")
except Exception as e:
logging.error(f"'{context_name}' 클러스터에서 알 수 없는 에러 발생: {e}")
return abnormal_pods_list
def analyze_pods_python(pods):
"""Python으로 Pod 데이터를 분석하고 포맷에 맞는 문자열을 생성합니다."""
timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
results = []
for pod in pods:
reason_str = ", ".join(pod.get('reasons', []))
line = f"{timestamp} | {pod['cluster']} | {pod['namespace']} | {pod['pod_name']} | {pod['status']} | {pod['node']} | {reason_str}"
results.append(line)
return results
def save_results_to_file(results):
"""분석 결과를 오늘 날짜의 파일에 저장합니다."""
if not results:
logging.info("비정상 Pod가 발견되지 않았습니다. 파일에 저장할 내용이 없습니다.")
return
ensure_dir(DATA_DIR)
today_str = datetime.now().strftime('%Y%m%d')
file_path = DATA_DIR / f"abnormal_pods_{today_str}.txt"
lock_path = file_path.with_suffix('.lock')
logging.info(f"결과를 '{file_path}' 파일에 저장합니다...")
try:
# 파일 락을 사용하여 동시 쓰기 방지
with filelock.FileLock(lock_path, timeout=10):
with open(file_path, 'a', encoding='utf-8') as f:
for line in results:
f.write(line + '\n')
logging.info(f"{len(results)}개의 비정상 Pod 정보를 파일에 성공적으로 저장했습니다.")
except filelock.Timeout:
logging.error(f"파일 락을 얻는 데 실패했습니다: {lock_path}")
except Exception as e:
logging.error(f"파일 저장 중 오류 발생: {e}")
def compare_and_report():
"""어제와 오늘의 데이터를 비교하여 리포트를 생성합니다."""
today_str = datetime.now().strftime('%Y%m%d')
yesterday_str = (datetime.now() - timedelta(days=1)).strftime('%Y%m%d')
today_file = DATA_DIR / f"abnormal_pods_{today_str}.txt"
yesterday_file = DATA_DIR / f"abnormal_pods_{yesterday_str}.txt"
if not today_file.exists():
logging.warning("오늘의 데이터 파일이 없어 비교를 건너뜁니다.")
return
def get_key(line):
parts = line.strip().split(' | ')
# cluster | namespace | pod
return f"{parts[1]}|{parts[2]}|{parts[3]}"
try:
with open(today_file, 'r', encoding='utf-8') as f:
today_set = {get_key(line) for line in f}
except Exception as e:
logging.error(f"오늘 데이터 파일 읽기 실패: {e}")
return
yesterday_set = set()
if yesterday_file.exists():
try:
with open(yesterday_file, 'r', encoding='utf-8') as f:
yesterday_set = {get_key(line) for line in f}
except Exception as e:
logging.error(f"어제 데이터 파일 읽기 실패: {e}")
new_issues = today_set - yesterday_set
resolved_issues = yesterday_set - today_set
ongoing_issues = today_set.intersection(yesterday_set)
logging.info("\n--- 일일 비교 리포트 ---")
logging.info(f"신규 이슈: {len(new_issues)} 건")
logging.info(f"해결된 이슈: {len(resolved_issues)} 건")
logging.info(f"지속되는 이슈: {len(ongoing_issues)} 건")
logging.info("----------------------")
def main():
"""메인 CLI 실행 함수"""
logging.info("Kubernetes Pod 모니터링을 시작합니다.")
all_abnormal_pods = []
try:
contexts, active_context = config.list_kube_config_contexts()
if not contexts:
logging.error("Kubeconfig 파일에 컨텍스트가 없습니다.")
return
logging.info(f"사용 가능한 클러스터(컨텍스트): {[context['name'] for context in contexts]}")
for context in contexts:
context_name = context['name']
logging.info(f"--- '{context_name}' 클러스터 점검 시작 ---")
try:
core_v1 = client.CoreV1Api(api_client=config.new_client_from_config(context=context_name))
abnormal_pods = get_abnormal_pods(context_name, core_v1)
all_abnormal_pods.extend(abnormal_pods)
logging.info(f"'{context_name}' 클러스터에서 {len(abnormal_pods)}개의 비정상 Pod를 발견했습니다.")
except Exception as e:
logging.error(f"'{context_name}' 클러스터 처리 중 에러: {e}")
except config.ConfigException:
logging.error("Kubeconfig 파일을 찾을 수 없거나 설정에 문제가 있습니다. ~/.kube/config 파일을 확인해주세요.")
return
if not all_abnormal_pods:
logging.info("모든 클러스터에서 비정상 Pod를 발견하지 못했습니다.")
else:
if RUST_ENABLED:
# Rust 함수는 JSON 문자열을 인자로 받음
pods_json = json.dumps(all_abnormal_pods)
analyzed_results = rust_analyzer.analyze_pods_rust(pods_json)
else:
# Python 함수는 dict list를 인자로 받음
analyzed_results = analyze_pods_python(all_abnormal_pods)
save_results_to_file(analyzed_results)
compare_and_report()
logging.info("모니터링 작업이 완료되었습니다.")
if name == "main":
main()
EOF
--- 8. 웹 서버 (web_server.py) 생성 ---
echo "✅ [8/9] 웹 대시보드 서버(web_server.py)를 생성합니다..."
cat << 'EOF' > web_server.py
import os
import json
from pathlib import Path
from datetime import datetime, timedelta
import logging
from flask import Flask, jsonify, render_template, request
from flask_cors import CORS
import threading
import time
main.py의 로직을 재사용
from main import get_abnormal_pods, analyze_pods_python, save_results_to_file, RUST_ENABLED, DATA_DIR, ensure_dir
if RUST_ENABLED:
import rust_analyzer
로깅 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
app = Flask(name)
CORS 설정으로 모든 오리진에서의 요청을 허용
CORS(app)
백그라운드 스레드 상태
background_thread = None
is_checking = threading.Lock()
def parse_line(line):
"""데이터 라인을 파싱하여 딕셔너리로 반환"""
try:
parts = line.strip().split(' | ')
if len(parts) == 7:
return {
"timestamp": parts[0],
"cluster": parts[1],
"namespace": parts[2],
"pod": parts[3],
"status": parts[4],
"node": parts[5],
"reasons": parts[6],
}
except Exception:
return None
return None
def read_data_file(file_path):
"""데이터 파일을 읽어 파싱된 딕셔너리 리스트로 반환"""
if not file_path.exists():
return []
with open(file_path, 'r', encoding='utf-8') as f:
return [p for p in (parse_line(line) for line in f) if p]
@app.route('/')
def dashboard():
"""메인 대시보드 HTML을 렌더링"""
return render_template('dashboard.html')
@app.route('/api/stats')
def get_stats():
"""현재 통계 정보를 JSON으로 반환"""
today_str = datetime.now().strftime('%Y%m%d')
today_file = DATA_DIR / f"abnormal_pods_{today_str}.txt"
today_data = read_data_file(today_file)
# 일일 비교
yesterday_str = (datetime.now() - timedelta(days=1)).strftime('%Y%m%d')
yesterday_file = DATA_DIR / f"abnormal_pods_{yesterday_str}.txt"
def get_key(pod):
return f"{pod['cluster']}|{pod['namespace']}|{pod['pod']}"
today_set = {get_key(p) for p in today_data}
yesterday_data = read_data_file(yesterday_file)
yesterday_set = {get_key(p) for p in yesterday_data}
return jsonify({
"current_abnormal": len(today_set),
"new_issues": len(today_set - yesterday_set),
"resolved_issues": len(yesterday_set - today_set),
"ongoing_issues": len(today_set.intersection(yesterday_set)),
})
@app.route('/api/issues/daily')
def get_daily_issues():
"""신규, 지속, 해결된 이슈 목록을 JSON으로 반환"""
today_str = datetime.now().strftime('%Y%m%d')
today_file = DATA_DIR / f"abnormal_pods_{today_str}.txt"
today_data = read_data_file(today_file)
yesterday_str = (datetime.now() - timedelta(days=1)).strftime('%Y%m%d')
yesterday_file = DATA_DIR / f"abnormal_pods_{yesterday_str}.txt"
yesterday_data = read_data_file(yesterday_file)
def get_key_map(data):
return {f"{p['cluster']}|{p['namespace']}|{p['pod']}": p for p in data}
today_map = get_key_map(today_data)
yesterday_map = get_key_map(yesterday_data)
today_keys = set(today_map.keys())
yesterday_keys = set(yesterday_map.keys())
new_keys = today_keys - yesterday_keys
resolved_keys = yesterday_keys - today_keys
ongoing_keys = today_keys.intersection(yesterday_keys)
return jsonify({
"new": [today_map[k] for k in new_keys],
"ongoing": [today_map[k] for k in ongoing_keys],
"resolved": [yesterday_map[k] for k in resolved_keys],
})
@app.route('/api/issues/history')
def get_history():
"""지난 7일간의 이슈 수 추이를 JSON으로 반환"""
history = []
for i in range(7):
date = datetime.now() - timedelta(days=i)
date_str = date.strftime('%Y%m%d')
file_path = DATA_DIR / f"abnormal_pods_{date_str}.txt"
count = 0
if file_path.exists():
with open(file_path, 'r', encoding='utf-8') as f:
# 유니크한 Pod 수를 셈
unique_pods = {line.strip().split(' | ')[3] for line in f if line.strip()}
count = len(unique_pods)
history.append({"date": date.strftime('%Y-%m-%d'), "count": count})
return jsonify(list(reversed(history)))
@app.route('/api/check', methods=['POST'])
def trigger_check():
"""수동으로 Pod 상태 점검을 시작"""
if is_checking.locked():
return jsonify({"status": "already_running", "message": "점검이 이미 실행 중입니다."}), 429
def run_check():
with is_checking:
logging.info("백그라운드 Pod 상태 점검을 시작합니다...")
# main.py의 main 함수를 호출하여 점검 수행
from main import main as run_cli_check
try:
run_cli_check()
except Exception as e:
logging.error(f"백그라운드 점검 중 오류 발생: {e}")
logging.info("백그라운드 Pod 상태 점검이 완료되었습니다.")
# 백그라운드 스레드에서 점검 실행
thread = threading.Thread(target=run_check)
thread.daemon = True
thread.start()
return jsonify({"status": "started", "message": "Pod 상태 점검을 시작했습니다."})
def background_scheduler():
"""30분마다 자동으로 Pod 상태를 점검하는 스케줄러"""
while True:
logging.info("자동 스케줄러: 30분 후 다음 점검을 실행합니다.")
time.sleep(1800) # 30분 대기
if not is_checking.locked():
logging.info("자동 스케줄러: 점검을 시작합니다.")
# 점검 로직은 /api/check와 동일
with is_checking:
from main import main as run_cli_check
try:
run_cli_check()
except Exception as e:
logging.error(f"자동 스케줄러 점검 중 오류 발생: {e}")
else:
logging.info("자동 스케줄러: 이전 점검이 아직 실행 중이므로 건너뜁니다.")
if name == 'main':
ensure_dir(DATA_DIR)
# 백그라운드 스케줄러 스레드 시작
scheduler_thread = threading.Thread(target=background_scheduler)
scheduler_thread.daemon = True
scheduler_thread.start()
# Flask 웹 서버 실행
app.run(host='0.0.0.0', port=5000, debug=False)
EOF
--- 9. 웹 대시보드 UI (dashboard.html) 생성 ---
echo "✅ [9/9] 웹 대시보드 UI(dashboard.html)를 생성합니다..."
cat << 'EOF' > "templates/dashboard.html"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Kubernetes Pod Monitor Dashboard</title>
<!-- Bootstrap 5 CSS -->
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
<!-- Bootstrap Icons -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css">
<!-- Plotly.js for charting -->
<script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
<style>
body { background-color: #f8f9fa; }
.card { box-shadow: 0 2px 4px rgba(0,0,0,.1); }
.stat-card .card-body { font-size: 1.5rem; }
.stat-card .card-title { font-size: 1rem; }
.table-responsive { max-height: 400px; }
#loading-spinner {
position: fixed; top: 50%; left: 50%; z-index: 1050;
transform: translate(-50%, -50%);
}
</style>
</head>
<body>
<div id="loading-spinner" class="spinner-border text-primary d-none" role="status">
<span class="visually-hidden">Loading...</span>
</div>
<div class="container-fluid mt-4">
<header class="d-flex justify-content-between align-items-center mb-4">
<h3><i class="bi bi-grid-1x2-fill"></i> K8s Pod Monitor Dashboard</h3>
<div>
<button id="manual-check-btn" class="btn btn-primary">
<i class="bi bi-arrow-clockwise"></i> 지금 점검
</button>
<span id="last-updated" class="text-muted ms-3"></span>
</div>
</header>
<!-- 통계 카드 -->
<div class="row">
<div class="col-md-3 mb-4">
<div class="card text-white bg-danger stat-card">
<div class="card-body">
<h5 class="card-title">현재 비정상 Pod</h5>
<p id="current-abnormal" class="card-text fw-bold">0</p>
</div>
</div>
</div>
<div class="col-md-3 mb-4">
<div class="card text-white bg-warning stat-card">
<div class="card-body">
<h5 class="card-title">오늘 신규 이슈</h5>
<p id="new-issues" class="card-text fw-bold">0</p>
</div>
</div>
</div>
<div class="col-md-3 mb-4">
<div class="card text-white bg-success stat-card">
<div class="card-body">
<h5 class="card-title">오늘 해결된 이슈</h5>
<p id="resolved-issues" class="card-text fw-bold">0</p>
</div>
</div>
</div>
<div class="col-md-3 mb-4">
<div class="card text-white bg-info stat-card">
<div class="card-body">
<h5 class="card-title">지속되는 이슈</h5>
<p id="ongoing-issues" class="card-text fw-bold">0</p>
</div>
</div>
</div>
</div>
<!-- 일일 비교 탭 -->
<div class="card mb-4">
<div class="card-header">
<ul class="nav nav-tabs card-header-tabs" id="issue-tabs" role="tablist">
<li class="nav-item" role="presentation">
<button class="nav-link active" id="new-tab" data-bs-toggle="tab" data-bs-target="#new" type="button" role="tab">신규 이슈</button>
</li>
<li class="nav-item" role="presentation">
<button class="nav-link" id="ongoing-tab" data-bs-toggle="tab" data-bs-target="#ongoing" type="button" role="tab">지속 이슈</button>
</li>
<li class="nav-item" role="presentation">
<button class="nav-link" id="resolved-tab" data-bs-toggle="tab" data-bs-target="#resolved" type="button" role="tab">해결된 이슈</button>
</li>
</ul>
</div>
<div class="card-body">
<div class="tab-content" id="issue-tabs-content">
<div class="tab-pane fade show active" id="new" role="tabpanel">
<div class="table-responsive">
<table class="table table-striped table-hover">
<thead><tr><th>Timestamp</th><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Status</th><th>Node</th><th>Reasons</th></tr></thead>
<tbody id="new-issues-table"></tbody>
</table>
</div>
</div>
<div class="tab-pane fade" id="ongoing" role="tabpanel">
<div class="table-responsive">
<table class="table table-striped table-hover">
<thead><tr><th>Timestamp</th><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Status</th><th>Node</th><th>Reasons</th></tr></thead>
<tbody id="ongoing-issues-table"></tbody>
</table>
</div>
</div>
<div class="tab-pane fade" id="resolved" role="tabpanel">
<div class="table-responsive">
<table class="table table-striped table-hover">
<thead><tr><th>Timestamp</th><th>Cluster</th><th>Namespace</th><th>Pod</th><th>Status</th><th>Node</th><th>Reasons</th></tr></thead>
<tbody id="resolved-issues-table"></tbody>
</table>
</div>
</div>
</div>
</div>
</div>
<!-- 차트 -->
<div class="row">
<div class="col-lg-6 mb-4">
<div class="card">
<div class="card-header">상태별 분포</div>
<div class="card-body"><div id="status-pie-chart"></div></div>
</div>
</div>
<div class="col-lg-6 mb-4">
<div class="card">
<div class="card-header">지난 7일간 이슈 추이</div>
<div class="card-body"><div id="history-line-chart"></div></div>
</div>
</div>
</div>
</div>
<!-- Bootstrap 5 JS -->
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
const API_BASE = window.location.origin;
const loadingSpinner = document.getElementById('loading-spinner');
function showLoading() { loadingSpinner.classList.remove('d-none'); }
function hideLoading() { loadingSpinner.classList.add('d-none'); }
async function fetchData(endpoint) {
try {
const response = await fetch(${API_BASE}${endpoint});
if (!response.ok) {
throw new Error(HTTP error! status: ${response.status});
}
return await response.json();
} catch (error) {
console.error(Error fetching ${endpoint}:, error);
alert(데이터를 가져오는 데 실패했습니다: ${error.message});
return null;
}
}
function updateStats(data) {
document.getElementById('current-abnormal').textContent = data.current_abnormal;
document.getElementById('new-issues').textContent = data.new_issues;
document.getElementById('resolved-issues').textContent = data.resolved_issues;
document.getElementById('ongoing-issues').textContent = data.ongoing_issues;
}
function createTableRow(item) {
return <tr> <td>${item.timestamp}</td> <td>${item.cluster}</td> <td>${item.namespace}</td> <td>${item.pod}</td> <td><span class="badge bg-danger">${item.status}</span></td> <td>${item.node}</td> <td>${item.reasons}</td> </tr>;
}
function populateTable(tableId, data) {
const tableBody = document.getElementById(tableId);
if (!data || data.length === 0) {
tableBody.innerHTML = '<tr><td colspan="7" class="text-center">해당 이슈가 없습니다.</td></tr>';
return;
}
tableBody.innerHTML = data.map(createTableRow).join('');
}
async function updateDailyIssues() {
const data = await fetchData('/api/issues/daily');
if (data) {
populateTable('new-issues-table', data.new);
populateTable('ongoing-issues-table', data.ongoing);
populateTable('resolved-issues-table', data.resolved);
// 파이 차트 데이터 생성 (신규+지속)
const currentIssues = [...data.new, ...data.ongoing];
const statusCounts = currentIssues.reduce((acc, item) => {
acc[item.status] = (acc[item.status] || 0) + 1;
return acc;
}, {});
drawPieChart(Object.keys(statusCounts), Object.values(statusCounts));
}
}
function drawPieChart(labels, values) {
if (labels.length === 0) {
document.getElementById('status-pie-chart').innerHTML = '<p class="text-center">데이터 없음</p>';
return;
}
const data = [{
values: values,
labels: labels,
type: 'pie',
hole: .4
}];
const layout = { title: '현재 비정상 Pod 상태 분포', showlegend: true };
Plotly.newPlot('status-pie-chart', data, layout, {responsive: true});
}
async function drawHistoryChart() {
const data = await fetchData('/api/issues/history');
if(data) {
const dates = data.map(d => d.date);
const counts = data.map(d => d.count);
const trace = {
x: dates,
y: counts,
type: 'scatter',
mode: 'lines+markers',
name: '비정상 Pod 수'
};
const layout = { title: '일일 비정상 Pod 수 추이', xaxis: { title: '날짜' }, yaxis: { title: 'Pod 수' } };
Plotly.newPlot('history-line-chart', [trace], layout, {responsive: true});
}
}
function updateLastUpdated() {
const now = new Date();
document.getElementById('last-updated').textContent = 마지막 업데이트: ${now.toLocaleTimeString()};
}
async function fullUpdate() {
showLoading();
await Promise.all([
fetchData('/api/stats').then(updateStats),
updateDailyIssues(),
drawHistoryChart()
]);
updateLastUpdated();
hideLoading();
}
document.getElementById('manual-check-btn').addEventListener('click', async () => {
showLoading();
try {
const response = await fetch(${API_BASE}/api/check, { method: 'POST' });
const result = await response.json();
alert(result.message);
if (response.ok) {
// 점검 시작 후 잠시 기다렸다가 데이터 새로고침
setTimeout(fullUpdate, 5000);
}
} catch (error) {
alert(점검 요청 실패: ${error});
} finally {
hideLoading();
}
});
// 페이지 로드 시 초기 데이터 로드
document.addEventListener('DOMContentLoaded', fullUpdate);
// 5분마다 자동 새로고침
setInterval(fullUpdate, 300000);
</script>
</body>
</html>
EOF
--- 최종 안내 ---
echo ""
echo "🎉 [성공] 프로젝트 생성이 완료되었습니다! ($PROJECT_NAME)"
echo "------------------------------------------------------------------"
echo "다음 단계를 진행하세요:"
echo ""
echo "1. 프로젝트 디렉터리로 이동:"
echo "   cd $PROJECT_NAME"
echo ""
echo "2. 의존성 설치 및 빌드:"
echo "   ./build.sh"
echo ""
echo "3. CLI 모드 테스트:"
echo "   python main.py"
echo ""
echo "4. 웹 대시보드 실행:"
echo "   python web_server.py"
echo "   (웹 브라우저에서 http://127.0.0.1:5000 주소로 접속)"
echo "------------------------------------------------------------------"

