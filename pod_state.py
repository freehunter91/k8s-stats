#!/usr/bin/env python3
"""
Kubernetes Pod Abnormality Monitor

이 스크립트는 여러 Kubernetes 클러스터에서 비정상적인 Pod를 모니터링하고
결과를 파일로 저장합니다.
"""

import os
import logging
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Dict, Any
from enum import Enum

from kubernetes import config, client
from kubernetes.client.rest import ApiException
import requests


class PodStatus(Enum):
    """Pod 상태 열거형"""
    FAILED = "Failed"
    UNKNOWN = "Unknown"
    PENDING = "Pending"
    CONNECTION_TIMEOUT = "CONNECTION_TIMEOUT"
    API_ERROR = "API_ERROR"
    UNEXPECTED_ERROR = "UNEXPECTED_ERROR"


@dataclass
class Config:
    """애플리케이션 설정"""
    long_term_pending_threshold_minutes: int = 10
    api_call_timeout_seconds: int = 60
    output_directory: str = "abnormal_pod_logs"
    log_level: str = "INFO"


@dataclass
class AbnormalPodInfo:
    """비정상 Pod 정보를 담는 데이터 클래스"""
    timestamp: str
    cluster_name: str
    namespace: str
    pod_name: str
    status: str
    node: str
    abnormal_reasons: str

    def to_log_line(self) -> str:
        """로그 파일 형식으로 변환"""
        return (
            f"{self.timestamp} | "
            f"{self.cluster_name} | "
            f"{self.namespace} | "
            f"{self.pod_name} | "
            f"{self.status} | "
            f"{self.node} | "
            f"{self.abnormal_reasons}\n"
        )


class KubernetesClient:
    """Kubernetes API 클라이언트 래퍼"""
    
    def __init__(self, context_name: str, timeout: int):
        self.context_name = context_name
        self.timeout = timeout
        self._client = None
    
    def connect(self) -> bool:
        """클러스터에 연결"""
        try:
            config.load_kube_config(context=self.context_name)
            self._client = client.CoreV1Api()
            return True
        except Exception as e:
            logging.error(f"Failed to connect to cluster {self.context_name}: {e}")
            return False
    
    def list_all_pods(self) -> Optional[client.V1PodList]:
        """모든 네임스페이스의 Pod 목록을 가져옴"""
        if not self._client:
            return None
        
        try:
            return self._client.list_pod_for_all_namespaces(
                watch=False, 
                _request_timeout=self.timeout
            )
        except requests.exceptions.Timeout:
            raise TimeoutError(f"API call timed out after {self.timeout} seconds")
        except ApiException as e:
            raise e


class PodAnalyzer:
    """Pod 상태 분석기"""
    
    def __init__(self, pending_threshold_minutes: int):
        self.pending_threshold_minutes = pending_threshold_minutes
    
    def is_pod_abnormal(self, pod: client.V1Pod) -> List[str]:
        """Pod가 비정상 상태인지 확인하고 이유를 반환"""
        abnormal_reasons = []
        
        # Phase 기반 분석
        abnormal_reasons.extend(self._analyze_pod_phase(pod))
        
        # 컨테이너 상태 분석
        abnormal_reasons.extend(self._analyze_container_statuses(pod))
        
        return abnormal_reasons
    
    def _analyze_pod_phase(self, pod: client.V1Pod) -> List[str]:
        """Pod Phase 분석"""
        reasons = []
        phase = pod.status.phase
        
        if phase in [PodStatus.FAILED.value, PodStatus.UNKNOWN.value]:
            reason_text = f"Phase: {phase}"
            if pod.status.reason:
                reason_text += f" ({pod.status.reason})"
            if pod.status.message:
                reason_text += f" - {pod.status.message}"
            reasons.append(reason_text)
            
        elif phase == PodStatus.PENDING.value:
            reasons.extend(self._analyze_pending_pod(pod))
        
        return reasons
    
    def _get_container_state(self, state: Optional[client.V1ContainerState]) -> str:
        """컨테이너 상태를 안전하게 가져오기"""
        if not state:
            return 'Unknown'
        
        # V1ContainerState의 각 상태를 직접 확인
        if state.running:
            return 'Running'
        elif state.waiting:
            return f'Waiting ({state.waiting.reason or "Unknown reason"})'
        elif state.terminated:
            return f'Terminated ({state.terminated.reason or "Unknown reason"})'
        else:
            return 'Unknown'
    
    def _analyze_pending_pod(self, pod: client.V1Pod) -> List[str]:
        """Pending 상태 Pod 분석"""
        reasons = []
        
        # 장시간 대기 체크
        try:
            creation_time = datetime.fromisoformat(
                pod.metadata.creation_timestamp.replace('Z', '+00:00')
            )
            current_time = datetime.now(timezone.utc)
            pending_duration = current_time - creation_time
            
            if pending_duration.total_seconds() > (self.pending_threshold_minutes * 60):
                reasons.append(
                    f"Phase: Long-term Pending ({pending_duration.total_seconds() / 60:.1f} min)"
                )
                return reasons
                
        except (ValueError, Exception) as e:
            reasons.append(f"Phase: Pending - Could not parse creation timestamp ({e})")
            return reasons
        
        # 일반적인 Pending 원인 분석
        reasons.extend(self._analyze_pending_conditions(pod))
        
        return reasons
    
    def _analyze_pending_conditions(self, pod: client.V1Pod) -> List[str]:
        """Pending Pod의 조건 분석"""
        reasons = []
        
        # Pod 조건 확인
        if pod.status.conditions:
            for condition in pod.status.conditions:
                if condition.type == "PodScheduled" and condition.status == "False":
                    reasons.append(
                        f"Phase: Pending - Not Scheduled ({condition.reason}: {condition.message})"
                    )
                elif condition.type == "Initialized" and condition.status == "False":
                    reasons.append(
                        f"Phase: Pending - Not Initialized ({condition.reason}: {condition.message})"
                    )
        
        # 컨테이너 대기 상태 확인
        if not reasons and pod.status.container_statuses:
            for container_status in pod.status.container_statuses:
                if container_status.state and container_status.state.waiting:
                    reason = container_status.state.waiting.reason
                    message = container_status.state.waiting.message or ""
                    if reason in ["ImagePullBackOff", "ErrImagePull", "ContainerCreating"]:
                        reasons.append(
                            f"Phase: Pending - Container Waiting ({reason}: {message})"
                        )
        
        return reasons
    
    def _analyze_container_statuses(self, pod: client.V1Pod) -> List[str]:
        """컨테이너 상태 분석"""
        reasons = []
        
        if not pod.status.container_statuses:
            return reasons
        
        for container_status in pod.status.container_statuses:
            container_name = container_status.name
            
            # Waiting 상태 분석
            if container_status.state and container_status.state.waiting:
                reason = container_status.state.waiting.reason
                message = container_status.state.waiting.message or ""
                if reason in ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull"]:
                    reasons.append(
                        f"Container '{container_name}' Waiting: {reason} - {message}"
                    )
            
            # Terminated 상태 분석
            if container_status.state and container_status.state.terminated:
                terminated = container_status.state.terminated
                if (terminated.reason in ["Error", "OOMKilled"] or 
                    (terminated.exit_code is not None and terminated.exit_code != 0)):
                    reasons.append(
                        f"Container '{container_name}' Terminated: {terminated.reason} "
                        f"(Exit Code: {terminated.exit_code}) - {terminated.message or ''}"
                    )
            
            # Ready 상태 분석
            if (container_status.ready is False and 
                not (container_status.state and 
                     (container_status.state.waiting or container_status.state.terminated))):
                current_state = self._get_container_state(container_status.state)
                reasons.append(
                    f"Container '{container_name}' Not Ready (Current State: {current_state})"
                )
        
        return reasons


class ClusterMonitor:
    """클러스터 모니터링 담당"""
    
    def __init__(self, config: Config):
        self.config = config
        self.analyzer = PodAnalyzer(config.long_term_pending_threshold_minutes)
    
    def get_kubeconfig_contexts(self) -> List[str]:
        """kubeconfig에서 컨텍스트 목록 가져오기"""
        try:
            contexts, _ = config.list_kube_config_contexts()
            return [context['name'] for context in contexts]
        except config.ConfigException as e:
            logging.error(f"kubeconfig 파일을 찾거나 읽을 수 없습니다: {e}")
            return []
    
    def check_cluster(self, context_name: str) -> List[AbnormalPodInfo]:
        """단일 클러스터의 비정상 Pod 확인"""
        logging.info(f"클러스터 '{context_name}' 점검 시작")
        
        k8s_client = KubernetesClient(context_name, self.config.api_call_timeout_seconds)
        
        if not k8s_client.connect():
            return [self._create_error_pod_info(context_name, "CONNECTION_ERROR", "Failed to connect")]
        
        try:
            pods = k8s_client.list_all_pods()
            if not pods or not pods.items:
                logging.info(f"클러스터 '{context_name}'에 Pod가 없습니다")
                return []
            
            return self._analyze_pods(context_name, pods.items)
            
        except TimeoutError as e:
            logging.error(f"클러스터 '{context_name}' 타임아웃: {e}")
            return [self._create_error_pod_info(context_name, "CONNECTION_TIMEOUT", str(e))]
            
        except ApiException as e:
            logging.error(f"클러스터 '{context_name}' API 오류: {e}")
            return [self._create_error_pod_info(context_name, "API_ERROR", f"{e.status} - {e.reason}")]
            
        except Exception as e:
            logging.error(f"클러스터 '{context_name}' 예기치 못한 오류: {e}")
            return [self._create_error_pod_info(context_name, "UNEXPECTED_ERROR", str(e))]
    
    def _analyze_pods(self, context_name: str, pods: List[client.V1Pod]) -> List[AbnormalPodInfo]:
        """Pod 목록 분석"""
        abnormal_pods = []
        current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        for pod in pods:
            abnormal_reasons = self.analyzer.is_pod_abnormal(pod)
            if abnormal_reasons:
                pod_info = AbnormalPodInfo(
                    timestamp=current_time,
                    cluster_name=context_name,
                    namespace=pod.metadata.namespace,
                    pod_name=pod.metadata.name,
                    status=pod.status.phase,
                    node=pod.spec.node_name or 'N/A',
                    abnormal_reasons="; ".join(abnormal_reasons)
                )
                abnormal_pods.append(pod_info)
                
                # 콘솔 출력
                self._log_abnormal_pod(pod_info)
        
        if not abnormal_pods:
            logging.info(f"클러스터 '{context_name}'에서 비정상 Pod를 찾지 못했습니다")
        
        return abnormal_pods
    
    def _create_error_pod_info(self, context_name: str, status: str, reason: str) -> AbnormalPodInfo:
        """오류 상황용 Pod 정보 생성"""
        return AbnormalPodInfo(
            timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            cluster_name=context_name,
            namespace="N/A",
            pod_name="N/A",
            status=status,
            node="N/A",
            abnormal_reasons=reason
        )
    
    def _log_abnormal_pod(self, pod_info: AbnormalPodInfo):
        """비정상 Pod 정보 콘솔 출력"""
        logging.warning(f"[경고] Pod: {pod_info.pod_name} (Namespace: {pod_info.namespace})")
        logging.warning(f"  - Node: {pod_info.node}")
        logging.warning(f"  - Status: {pod_info.status}")
        logging.warning(f"  - 비정상 원인: {pod_info.abnormal_reasons}")


class ResultSaver:
    """결과 저장 담당"""
    
    def __init__(self, output_dir: str):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
    
    def save_results(self, abnormal_pods: List[AbnormalPodInfo]):
        """결과를 파일로 저장"""
        if not abnormal_pods:
            logging.info("저장할 비정상 Pod 데이터가 없습니다")
            return
        
        file_path = self._get_output_file_path()
        
        try:
            with open(file_path, 'a', encoding='utf-8') as f:
                for pod_info in abnormal_pods:
                    f.write(pod_info.to_log_line())
            
            logging.info(f"데이터가 성공적으로 {file_path}에 저장되었습니다")
            
        except IOError as e:
            logging.error(f"파일 저장 중 오류 발생: {e}")
    
    def _get_output_file_path(self) -> Path:
        """출력 파일 경로 생성"""
        today_str = datetime.now().strftime("%Y%m%d")
        return self.output_dir / f"abnormal_pods_{today_str}.txt"


class PodMonitorApp:
    """메인 애플리케이션"""
    
    def __init__(self, config: Config):
        self.config = config
        self.monitor = ClusterMonitor(config)
        self.saver = ResultSaver(config.output_directory)
        self._setup_logging()
    
    def _setup_logging(self):
        """로깅 설정"""
        logging.basicConfig(
            level=getattr(logging, self.config.log_level),
            format='%(asctime)s - %(levelname)s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
    
    def run(self):
        """애플리케이션 실행"""
        contexts = self.monitor.get_kubeconfig_contexts()
        
        if not contexts:
            logging.error("조회할 Kubernetes 클러스터 컨텍스트가 없습니다")
            return
        
        logging.info(f"발견된 Kubernetes 컨텍스트: {', '.join(contexts)}")
        
        all_abnormal_pods = []
        
        for context in contexts:
            abnormal_pods = self.monitor.check_cluster(context)
            all_abnormal_pods.extend(abnormal_pods)
        
        logging.info("모든 클러스터 점검 완료")
        self.saver.save_results(all_abnormal_pods)


def main():
    """메인 함수"""
    config = Config()
    app = PodMonitorApp(config)
    app.run()


if __name__ == "__main__":
    main()