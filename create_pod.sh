#!/bin/bash

# ==============================================================================
# Python + Rust (PyO3) 하이브리드 프로젝트 생성 스크립트 (v2)
# ==============================================================================

# 스크립트 실행 중 오류가 발생하면 즉시 중단합니다.
set -e

# --- 1. 기본 프로젝트 설정 및 디렉터리 생성 ---
PROJECT_NAME="k8s-pod-monitor-hybrid"
RUST_CRATE_NAME="rust_analyzer"

echo "🚀 프로젝트 생성을 시작합니다: $PROJECT_NAME"
# 기존 디렉터리가 있다면 안전하게 삭제합니다.
rm -rf $PROJECT_NAME
mkdir $PROJECT_NAME
cd $PROJECT_NAME

# --- 2. Python 가상 환경 설정 ---
echo "🐍 Python 가상 환경(venv)을 생성합니다..."
python3 -m venv venv
source venv/bin/activate

echo "📦 Python 빌드 도구(maturin)를 설치합니다..."
pip install "maturin==1.7.0"

# --- 3. Maturin 프로젝트 설정 파일 (pyproject.toml) 생성 ---
# 이 파일은 maturin에게 프로젝트 구조와 빌드 방법을 알려줍니다.
echo "📝 pyproject.toml 파일을 생성합니다..."
cat << EOF > pyproject.toml
[build-system]
requires = ["maturin>=1.7,<2.0"]
build-backend = "maturin"

[project]
name = "$RUST_CRATE_NAME"
requires-python = ">=3.8"
classifiers = [
    "Programming Language :: Rust",
    "Programming Language :: Python :: 3",
]
EOF

# --- 4. 빌드 스크립트 (build.sh) 생성 ---
# 이 스크립트는 Rust 코드를 Python 모듈로 컴파일하고 설치하는 과정을 자동화합니다.
echo "🛠️ build.sh 스크립트를 생성합니다..."
cat << EOF > build.sh
#!/bin/bash
set -e

echo "🐍 Python 가상 환경을 활성화합니다..."
source ./venv/bin/activate

echo "⚙️ Maturin으로 Rust 모듈을 컴파일하고 설치합니다..."
# 'maturin develop'은 Rust 코드를 컴파일하여 현재 가상 환경에 바로 설치해줍니다.
maturin develop

echo "✅ 빌드 완료! Python에서 Rust 모듈을 사용할 수 있습니다."
EOF
chmod +x build.sh

# --- 5. 테스트용 Python 스크립트 (main.py) 생성 ---
echo "🐍 테스트용 main.py 파일을 생성합니다..."
cat << EOF > main.py
# 생성된 Rust 모듈을 import 합니다.
import $RUST_CRATE_NAME

def run_test():
    print("🚀 Python 스크립트에서 Rust 함수를 호출합니다.")

    # Rust 함수에 전달할 Python 딕셔너리 데이터입니다.
    pod_data = {
        "name": "my-app-pod-xyz789",
        "namespace": "production-asia",
        "cpu_usage_milli": 350,
        "is_critical": False
    }

    try:
        # Rust로 작성된 함수를 호출합니다.
        analysis_result = $RUST_CRATE_NAME.analyze_pod_info(pod_data)
        print("\n--- Rust로부터 받은 결과 ---")
        print(analysis_result)
        print("--------------------------\n")
        print("테스트 성공!")

    except Exception as e:
        print(f"Rust 함수 호출 중 오류 발생: {e}")
        print("테스트 실패. build.sh를 먼저 실행했는지 확인하세요.")

if __name__ == "__main__":
    run_test()
EOF

# --- 6. Rust 크레이트 생성 ---
echo "🦀 Rust 크레이트($RUST_CRATE_NAME) 디렉터리를 생성합니다..."
mkdir -p $RUST_CRATE_NAME/src

# --- 7. Rust 의존성 파일 (Cargo.toml) 생성 ---
echo "🦀 Cargo.toml 파일을 생성합니다..."
cat << EOF > $RUST_CRATE_NAME/Cargo.toml
[package]
name = "$RUST_CRATE_NAME"
version = "0.1.0"
edition = "2021"

[lib]
name = "$RUST_CRATE_NAME"
# Python이 동적으로 로드할 수 있는 라이브러리(cdylib)로 빌드합니다.
crate-type = ["cdylib"]

[dependencies]
# PyO3: Rust와 Python 간의 상호 작용을 위한 핵심 라이브러리
# "serde" 기능 활성화: Serde 라이브러리와의 연동을 가능하게 합니다.
pyo3 = { version = "0.22.0", features = ["serde"] }

# Serde: Rust 데이터 구조를 직렬화/역직렬화하기 위한 라이브러리
# "derive" 기능 활성화: 매크로를 통해 코드를 자동 생성합니다.
serde = { version = "1.0", features = ["derive"] }
EOF

# --- 8. Rust 소스 코드 (src/lib.rs) 생성 ---
echo "🦀 src/lib.rs 파일을 생성합니다..."
cat << EOF > $RUST_CRATE_NAME/src/lib.rs
// PyO3와 Serde 라이브러리를 가져옵니다.
use pyo3::prelude::*;
use serde::Deserialize;

// Python의 딕셔너리 객체가 변환될 Rust 구조체입니다.
// `#[derive(Deserialize)]`를 통해 JSON이나 다른 형식의 데이터를 이 구조체로 자동 변환할 수 있습니다.
#[derive(Deserialize, Debug)]
struct PodInfo {
    name: String,
    namespace: String,
    cpu_usage_milli: u32,
    is_critical: bool,
}

/// 이 함수는 Python 코드에서 호출할 수 있습니다.
/// `#[pyfunction]` 매크로가 이를 가능하게 합니다.
#[pyfunction]
fn analyze_pod_info(py: Python, py_obj: &PyAny) -> PyResult<String> {
    // pyo3_serde를 사용해 Python 딕셔너리 객체(&PyAny)를 PodInfo 구조체로 변환합니다.
    // 변환에 실패하면 오류를 반환합니다(?).
    let pod: PodInfo = pyo3_serde::from_py_dict(py_obj)?;

    // Rust 백엔드 터미널에 로그를 출력합니다.
    println!("[Rust Log] Received and parsed data: {:?}", pod);

    // 전달받은 데이터를 기반으로 분석 로직을 수행합니다.
    let priority = if pod.is_critical { "긴급" } else { "일반" };
    let analysis_result = format!(
        "파드 분석 완료:\n  - 이름: {}\n  - 네임스페이스: {}\n  - CPU 사용량: {}m\n  - 우선순위: {}",
        pod.name, pod.namespace, pod.cpu_usage_milli, priority
    );

    // 처리 결과를 Python 쪽으로 반환합니다.
    Ok(analysis_result)
}

/// 이 Python 모듈이 import될 때 어떤 함수들을 사용할 수 있는지 정의합니다.
#[pymodule]
fn $RUST_CRATE_NAME(_py: Python, m: &PyModule) -> PyResult<()> {
    // 위에서 정의한 analyze_pod_info 함수를 모듈에 추가합니다.
    m.add_function(wrap_pyfunction!(analyze_pod_info, m)?)?;
    Ok(())
}
EOF

# --- 최종 안내 ---
echo "\n🎉 프로젝트 생성이 완료되었습니다!"
echo "다음 단계를 진행하세요:"
echo "1. (필요시) 시스템 빌드 도구 설치"
echo "2. 빌드 스크립트 실행: ./build.sh"
echo "3. 테스트 스크립트 실행: python main.py"
echo "------------------------------------------------"

