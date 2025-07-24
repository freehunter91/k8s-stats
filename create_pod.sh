#!/bin/bash

# ==============================================================================
# Python + Rust (PyO3) 하이브리드 프로젝트 생성 스크립트 (최종 수정본)
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

echo "📦 필수 Python 라이브러리(maturin)를 설치합니다..."
pip install "maturin==1.7.0" # 버전 고정으로 안정성을 확보합니다.

# --- 3. Maturin 설정 파일 (pyproject.toml) 생성 ---
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

# --- 4. 올바르게 수정된 빌드 스크립트 (build.sh) 생성 ---
echo "🛠️ build.sh 스크립트를 생성합니다..."
cat << EOF > build.sh
#!/bin/bash
set -e

echo "🐍 Activating Python virtual environment..."
source ./venv/bin/activate

echo "⚙️ Compiling Rust module with Maturin..."
# Rust 라이브러리를 컴파일하고 즉시 현재 가상 환경에 설치합니다.
maturin develop

echo "✅ Build complete! The Rust module is ready for use."
EOF
chmod +x build.sh

# --- 5. 테스트용 Python 스크립트 (main.py) 생성 ---
echo "🐍 테스트용 main.py 파일을 생성합니다..."
cat << EOF > main.py
import $RUST_CRATE_NAME

def main():
    print("🚀 Python 스크립트에서 Rust 함수를 호출합니다.")

    # Rust 함수로 전달할 데이터 (Python Dictionary)
    pod_data = {
        "name": "my-app-pod-12345",
        "namespace": "production",
        "cpu_usage_milli": 250,
        "is_critical": True
    }

    try:
        # Rust 함수를 호출합니다.
        result = $RUST_CRATE_NAME.analyze_pod_info(pod_data)
        print("\n--- Rust로부터 받은 결과 ---")
        print(result)
        print("--------------------------\n")

    except Exception as e:
        print(f"오류 발생: {e}")

if __name__ == "__main__":
    main()
EOF

# --- 6. Rust 크레이트 디렉터리 및 소스 코드 생성 ---
echo "🦀 Rust 크레이트($RUST_CRATE_NAME)를 생성합니다..."
mkdir -p $RUST_CRATE_NAME/src

# --- 7. 올바르게 수정된 Cargo.toml 생성 ---
echo "🦀 Cargo.toml 파일을 생성합니다..."
cat << EOF > $RUST_CRATE_NAME/Cargo.toml
[package]
name = "$RUST_CRATE_NAME"
version = "0.1.0"
edition = "2021"

[lib]
name = "$RUST_CRATE_NAME"
crate-type = ["cdylib"] # Python 확장 모듈을 위한 설정입니다.

[dependencies]
# pyo3의 serde 기능을 활성화합니다.
pyo3 = { version = "0.22.0", features = ["serde"] }
# 역직렬화를 위한 serde입니다.
serde = { version = "1.0", features = ["derive"] }
EOF

# --- 8. 올바르게 수정된 Rust 소스 코드 (src/lib.rs) 생성 ---
echo "🦀 src/lib.rs 파일을 생성합니다..."
cat << EOF > $RUST_CRATE_NAME/src/lib.rs
use pyo3::prelude::*;
use serde::Deserialize;

// Python dict와 매핑될 Rust 구조체입니다.
// serde::Deserialize를 반드시 derive 해야 합니다.
#[derive(Deserialize, Debug)]
struct PodInfo {
    name: String,
    namespace: String,
    cpu_usage_milli: u32,
    is_critical: bool,
}

/// Python에서 호출할 함수입니다.
/// Python 객체를 인자로 받아 PodInfo 구조체로 변환하고 분석 결과를 문자열로 반환합니다.
#[pyfunction]
fn analyze_pod_info(py: Python, py_obj: &PyAny) -> PyResult<String> {
    // from_py_dict를 사용해 Python dict를 PodInfo 구조체로 안전하게 변환합니다.
    let pod: PodInfo = pyo3_serde::from_py_dict(py_obj)?;

    println!("[Rust-side Log] Received and parsed data: {:?}", pod);

    let status = if pod.is_critical { "긴급" } else { "일반" };
    let analysis_result = format!(
        "파드 분석 완료:\n  - 이름: {}\n  - 네임스페이스: {}\n  - CPU 사용량: {}m\n  - 등급: {}",
        pod.name, pod.namespace, pod.cpu_usage_milli, status
    );

    Ok(analysis_result)
}

/// Python 모듈을 정의합니다.
#[pymodule]
fn $RUST_CRATE_NAME(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(analyze_pod_info, m)?)?;
    Ok(())
}
EOF

# --- 최종 안내 ---
echo "\n🎉 프로젝트 생성이 완료되었습니다!"
echo "다음 단계를 진행하세요:"
echo "1. 빌드 실행: ./build.sh"
echo "2. Python 스크립트 실행: python main.py"
echo "------------------------------------------------"

