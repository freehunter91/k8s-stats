# Kubernetes Pod Monitor (v1.13 - Detailed Excel Export)

**오류 없이 즉시 실행 가능한 다중 클러스터** Kubernetes Pod 모니터링 시스템의 최종 완성 버전입니다.
**Excel 파일에 상세 이벤트(실패 원인)를 포함**하는 기능이 추가되었으며, 로컬 및 Docker 실행을 모두 지원합니다.

## 🌟 최종 기능 목록

- **📋 상세 Excel 보고서**: "Download Excel" 클릭 시, 당일 발생한 모든 비정상 Pod 목록과 함께 **각 Pod의 상세 이벤트 로그**가 포함된 포괄적인 보고서를 다운로드합니다.
- **인터랙티브 이벤트 조회**: 대시보드의 비정상 Pod 이름을 클릭하여 상세한 실패 원인이 담긴 이벤트 로그를 팝업으로 즉시 확인할 수 있습니다.
- **할당된 노드 정보 표시**: 모든 Pod 목록에 해당 Pod가 스케줄링된 **Node의 이름**이 표시됩니다.
- **Docker 기반 완벽한 배포**: `docker-compose up` 단 한 줄로 모든 의존성(Python, Rust, kubectl) 설치, 빌드, 실행이 완료됩니다.
- **OIDC/Keycloak 인증 자동화**: 스크립트 실행 시 **자동으로 `kubectl`을 호출**하여 인증 토큰을 갱신합니다.
- **정확한 탐지 로직**: Pod의 `phase`와 각 컨테이너의 `ready` 상태까지 점검하여 `CrashLoopBackOff` 등의 문제를 정확히 탐지합니다.

## 🔧 설치 및 실행

두 가지 방법 중 하나를 선택하여 실행할 수 있습니다.

### 방법 1: Docker로 실행 (권장)

가장 간단하고 안정적인 방법입니다. 로컬에 Python, Rust 등을 설치할 필요 없이 Docker만 있으면 됩니다.

#### 사전 요구사항
- Docker & Docker Compose

#### 실행 절차
```bash
# 1. 프로젝트 생성 (최초 1회)
#    이 스크립트를 create_k8s_monitor.sh 로 저장 후 실행
chmod +x create_k8s_monitor.sh
./create_k8s_monitor.sh
cd k8s-pod-monitor

# 2. 웹 대시보드 실행
docker-compose up --build

# 3. (선택) CLI 모드 실행
#    새 터미널을 열고 아래 명령어를 실행
docker-compose run --rm k8s-monitor cli
