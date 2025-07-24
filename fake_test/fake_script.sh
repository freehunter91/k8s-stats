apiVersion: v1
kind: Pod
metadata:
  name: error-pod-exit-code
  namespace: test2
spec:
  containers:
  - name: failing-container
    image: busybox
    command: ["sh", "-c"]
    args: ["echo 'This container will fail intentionally.'; exit 1"] # 고의적으로 exit code 1 반환
  restartPolicy: Always # 오류 발생 시 재시작 시도 (CrashLoopBackOff 유도)
