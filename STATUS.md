# 구현 현황 (2026-09-08)

[PLAN-rancher.md](PLAN-rancher.md) 를 이 클러스터(Rancher Desktop k3s)에 구현하고 Step 1~6 을 실제 실행·검증한 기록.
컨테이너 목록 설명은 [DOCKER-containers.md](DOCKER-containers.md), 사용법은 [README.md](README.md).

---

## 1. 완료된 것

| # | 항목 | 상태 | 근거 |
|---|---|---|---|
| 1 | 샘플 앱 (`app/`) | ✅ | Express + pino, `/health` `/work?ms=N` `/error` + 1s heartbeat. JSON 한 줄 로그 `{level,time,msg,method,path,status,latency_ms,trace_id}` |
| 2 | 이미지 빌드 | ✅ | `docker build -t sample-app:0.1.0` → 컨테이너 스모크 테스트 통과 |
| 3 | Loki (Helm `loki` 7.3.0) | ✅ Running | `loki-0` 2/2, SingleBinary + filesystem PVC 5Gi, svc `loki:3100` |
| 4 | Promtail (Helm `promtail` 6.17.1) | ✅ Running | DaemonSet `promtail-zs2p6`, pipeline `docker: {}` 로 교체 |
| 5 | Grafana (Helm `grafana` 10.5.15) | ✅ Running | Loki 데이터소스 + "sample-app logs" 대시보드 프로비저닝, PVC 1Gi(비번/변경 유지), health = OK |
| 6 | 샘플 앱 배포 (`deploy/sample-app`) | ✅ Running | `kubectl apply -k` → Deployment 2/2, svc `sample-app:80` |
| 7 | ArgoCD (stable manifests) | ✅ Running | 7개 파드 Running, admin 로그인 토큰 발급 확인 |
| 8 | 로그 파이프라인 E2E | ✅ 검증 | 앱 → Promtail → Loki → LogQL 조회까지 실제 데이터 확인 |

### 검증한 LogQL (실제 결과 반환 확인)

```logql
{namespace="sample-app"}                             # heartbeat/request 로그 스트림
{namespace="sample-app"} | json | level="error"      # /error 500 건만
{namespace="sample-app"} | json | latency_ms > 100    # 파싱된 숫자 필드 필터
```

Loki 쿼리 메트릭에서 `total_lines` 증가, `| json` 필터 정상 동작 확인.

---

## 2. 계획서 대비 조정 사항 (이 클러스터 특성)

| PLAN-rancher.md 가정 | 실제 | 대응 | 반영 위치 |
|---|---|---|---|
| containerd 엔진 + `nerdctl --namespace k8s.io build` | **cri-dockerd (`docker://29.5.3`)** | `docker build` → `imagePullPolicy: IfNotPresent` 로 k3s 가 로컬 이미지 사용 | `scripts/01-build-image.ps1` |
| Traefik Ingress + `*.localhost` | **Traefik 미설치** (k3s `--disable=traefik`) | Ingress 리소스 없이 `kubectl port-forward` | `scripts/05-port-forward.ps1`, ingress.yaml 미생성 |
| Promtail 기본 `cri: {}` stage | **로그가 Docker JSON 포맷** (`{"log","stream","time"}`) | pipeline stage 를 `docker: {}` 로 교체. 안 하면 `\| json` 이 outer wrapper 만 파싱해 `level` 필터 전부 실패 | `infra/promtail-values.yaml` |
| `kubectl apply` 로 ArgoCD 설치 | ApplicationSet CRD 가 262KB 초과 | `kubectl apply --server-side --force-conflicts` | `scripts/04-install-argocd.ps1` |

> 첫 시도에서 로그가 Loki 엔 들어오는데 `level="error"` 필터가 0건이라 원인 추적 → cri-dockerd 의 Docker JSON 로그 포맷 문제로 확인, promtail pipeline 수정 후 해결.

---

## 3. 현재 클러스터 상태

```
namespace     workload                         status
logging       loki-0                           2/2  Running   (Helm loki 7.3.0)
logging       promtail (DaemonSet)             1/1  Running   (Helm promtail 6.17.1)
monitoring    grafana                          1/1  Running   (Helm grafana 10.5.15)
sample-app    sample-app (Deployment, x2)      2/2  Running   (image sample-app:0.1.0)
argocd        7 pods (server/repo/controller…) 1/1  Running   (stable manifests)
```

k8s 네임스페이스 4개 추가됨: `logging`, `monitoring`, `sample-app`, `argocd`.
기존 워크로드(kube-system) 및 중지된 개인 컨테이너에는 영향 없음.

heartbeat 로그(파드당 1줄/초)가 계속 쌓이는 중 — 필요 없으면
`deploy/sample-app/deployment.yaml` 의 `HEARTBEAT` env 를 `"false"` 로.

---

## 4. GitOps 연결 (Step 7)

- ✅ 저장소: `https://github.com/syleemz/kube-test.git` push 완료
- ✅ `deploy/argocd/application.yaml` 적용됨 → ArgoCD `sample-app` = **Synced**
  (`path: deploy/sample-app`, auto-sync + prune + selfHeal)

### 남은 것: E2E 검증 (Step 8)
   - `sample-app:0.2.0` 빌드 → 레포에서 `deployment.yaml` 태그 변경 push → 자동 Sync
   - self-heal: `kubectl -n sample-app scale deploy/sample-app --replicas=5` → 2 로 복귀
   - prune: 레포에서 `service.yaml` 삭제 push → 클러스터에서도 삭제

Bitbucket 사용 시 [PLAN-bitbucket.md](PLAN-bitbucket.md).

---

## 5. 접근 / 정리

```powershell
./scripts/05-port-forward.ps1     # Grafana :3000, App :8080, ArgoCD :8081
./scripts/99-teardown.ps1         # 4개 네임스페이스 + Helm 릴리스 + 이미지 제거
```

- Grafana  http://localhost:3000  (admin / 초기 비번은 `02-install-observability.ps1` 출력, 이후 변경한 값)
- App      http://localhost:8080/health
- ArgoCD   https://localhost:8081  (admin / 아래 명령으로 조회)

ArgoCD 초기 admin 비밀번호:
```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' |
  %{ [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

---

## 6. 파일 목록

| 경로 | 내용 |
|---|---|
| `app/src/server.js` | 샘플 앱 (Express + pino) |
| `app/Dockerfile` | `node:24-alpine`, non-root |
| `deploy/sample-app/` | deployment(replicas 2) · service · kustomization |
| `deploy/argocd/application.yaml` | ArgoCD Application (repoURL 교체 필요) |
| `infra/loki-values.yaml` | SingleBinary + filesystem |
| `infra/promtail-values.yaml` | clients URL + `docker` pipeline stage |
| `infra/grafana-values.yaml` | Loki 데이터소스, adminPassword `admin`, PVC 1Gi, 대시보드 프로비저닝 |
| `infra/grafana-dashboard-sample-app.yaml` | "sample-app logs" 대시보드 ConfigMap (에러/5xx/req·s/p95/추이/로그 7패널) |
| `scripts/01`~`05`, `99` | 빌드 → 관측성 → 앱 배포 → ArgoCD → port-forward / teardown |
| `scripts/10-pause.ps1` / `11-resume.ps1` | 테스트 스택 일시중지/재개 (replicas 0 ↔ 복원, argocd self-heal 고려해 controller 먼저 정지) |
| `README.md` | 실행 순서 + 검증 |
| `DOCKER-containers.md` | `docker ps` 항목 설명 |
| `PLAN.md` / `PLAN-kind.md` / `PLAN-rancher.md` | 계획서 3종 |
| `PLAN-bitbucket.md` / `LOGS-console.md` / `GRAFANA-logs.md` | 참조 문서 |
