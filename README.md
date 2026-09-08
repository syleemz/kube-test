# kube-test — 로컬 K8s 관측성 + GitOps 테스트

[PLAN-rancher.md](PLAN-rancher.md) 구현체. Rancher Desktop 내장 k3s 에
샘플 앱 → Promtail → Loki → Grafana 로그 파이프라인과 ArgoCD GitOps 를 구성한다.

## 이 환경에 맞춘 조정

| 계획서 | 실제 환경 | 대응 |
|---|---|---|
| 컨테이너 엔진 containerd + `nerdctl` | **cri-dockerd (`docker://`)** | `docker build` 만으로 k3s 가 이미지 인식 (`01-build-image.ps1`) |
| Traefik Ingress + `*.localhost` | **Traefik 미설치** | Ingress 없이 `kubectl port-forward` (`05-port-forward.ps1`) |
| Promtail 기본 `cri` 파이프라인 | **cri-dockerd 는 로그가 Docker JSON 포맷** | `promtail-values.yaml` 에서 stage 를 `docker: {}` 로 교체 (안 하면 `| json` 파싱 실패) |

검증 완료 차트 버전 (2026-09): loki 7.3.0 / promtail 6.17.1 / grafana 10.5.15, ArgoCD stable.
ArgoCD 설치는 `--server-side` 필요 (ApplicationSet CRD 크기).

## 구조

```
app/                     샘플 앱 (Express + pino JSON 로그)
  src/server.js          /health, /work?ms=N, /error, HEARTBEAT 로그
deploy/
  sample-app/            k8s 매니페스트 (ArgoCD 소스 = GitHub 레포에 push)
  argocd/application.yaml ArgoCD Application (repoURL 교체 필요)
infra/                   Loki / Promtail / Grafana Helm values (로컬 직접 설치)
scripts/                 01~05 실행 + 99 teardown (PowerShell)
```

## 실행 순서

```powershell
# 1. 샘플 앱 이미지 빌드
./scripts/01-build-image.ps1

# 2. 관측성 스택 (logging / monitoring 네임스페이스)
./scripts/02-install-observability.ps1

# 3. 샘플 앱 배포 (GitOps 전, 수동 검증용)
./scripts/03-deploy-sample-app.ps1

# 4. ArgoCD 설치
./scripts/04-install-argocd.ps1

# 5. 접근용 port-forward (백그라운드 job)
./scripts/05-port-forward.ps1
```

## 검증 (PLAN-rancher.md Step 대응)

### Step 4 — 샘플 앱

```powershell
curl http://localhost:8080/health
curl "http://localhost:8080/work?ms=200"
curl http://localhost:8080/error
kubectl -n sample-app logs deploy/sample-app --tail=20
```

트래픽 생성 루프:
```powershell
while ($true) {
  curl -s "http://localhost:8080/work?ms=$(Get-Random -Max 400)" | Out-Null
  if ((Get-Random -Max 5) -eq 0) { curl -s http://localhost:8080/error | Out-Null }
  Start-Sleep -Milliseconds 500
}
```

### Step 5 — Loki 조회

Grafana http://localhost:3000 (admin/admin) → Explore → Loki:

```logql
{namespace="sample-app"}
{namespace="sample-app"} | json | level="error"
{namespace="sample-app"} | json | latency_ms > 100
sum(rate({namespace="sample-app"} | json | level="error" [5m]))
```

자세한 Grafana 사용법은 [GRAFANA-logs.md](GRAFANA-logs.md), CLI 는 [LOGS-console.md](LOGS-console.md).

### Step 6~8 — ArgoCD GitOps

1. 이 저장소를 GitHub 퍼블릭 레포로 push (예: `kube-test`).
2. `deploy/argocd/application.yaml` 의 `repoURL` 을 그 레포 URL 로 수정.
3. 수동 배포분 제거 후 ArgoCD 에 위임:
   ```powershell
   kubectl delete -k deploy/sample-app
   kubectl apply -f deploy/argocd/application.yaml
   ```
4. ArgoCD https://localhost:8081 → `sample-app` 이 `Synced` + `Healthy`.
5. E2E: 이미지 태그 `0.2.0` 빌드 → 레포에서 `deployment.yaml` 태그 변경 push → 자동 Sync 확인.
   self-heal: `kubectl -n sample-app scale deploy/sample-app --replicas=5` → 2 로 복귀.

## 정리

```powershell
./scripts/99-teardown.ps1
```

Bitbucket 을 쓸 경우 [PLAN-bitbucket.md](PLAN-bitbucket.md) 참고.
