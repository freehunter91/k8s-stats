# Kubernetes Pod Monitor (v1.7)

**오류 없이 즉시 실행 가능한 다중 클러스터** Kubernetes Pod 모니터링 시스템입니다.
**Keycloak/OIDC 인증 환경을 완벽하게 지원**하고 **Rust 빌드 경로 문제를 해결**한 최종 안정화 버전입니다.

## 🌟 주요 기능

- **OIDC/Keycloak 인증 자동화**: 스크립트 실행 시 **자동으로 `kubectl`을 호출**하여 인증 토큰을 갱신합니다. 더 이상 수동으로 `kubectl`을 실행할 필요가 없습니다.
- **정확한 탐지 로직**: Pod의 전체 `phase`뿐만 아니라 각 컨테이너의 개별 상태(`ready`)까지 점검하여 `CrashLoopBackOff` 등의 숨겨진 문제를 정확히 탐지합니다.
- **안정적인 빌드**: Rust 모듈 빌드 시 정확한 경로를 찾아 설치하도록 `build.sh` 스크립트가 수정되었습니다.
- **다중 클러스터 지원**: `kubeconfig`에 있는 모든 컨텍스트를 자동으로 순회하며 결과를 통합합니다.
- **명확한 실행 피드백**: 분석 시 Rust 가속 모드(🚀) 또는 순수 Python 모드(🐍)로 실행되는지 터미널에 배너를 표시합니다.


## 🔧 설치 및 실행

### ⚠️ 새로운 사전 요구사항

- **`kubectl`**: 이 스크립트는 내부적으로 `kubectl` 명령을 사용하여 OIDC 인증을 처리하므로, **`kubectl`이 반드시 설치되어 있고 시스템 PATH에 등록**되어 있어야 합니다.
- **올바른 `KUBECONFIG` 환경**: 터미널의 `kubectl`과 스크립트가 동일한 `kubeconfig` 파일을 보도록 환경을 맞춰주세요. (가장 쉬운 방법: `unset KUBECONFIG`)

### 1. 프로젝트 생성 (최초 1회)
```bash
# 이 스크립트를 복사하여 create_k8s_monitor.sh 파일로 저장합니다.
chmod +x create_k8s_monitor.sh
./create_k8s_monitor.sh
