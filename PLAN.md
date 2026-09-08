# 로컬 K8s 관측성 + GitOps 테스트 계획

로컬에서 샘플 애플리케이션을 만들고 **minikube + Grafana Loki + Promtail + ArgoCD**로
로그 수집 및 GitOps 배포 파이프라인을 구성/검증한다.

---

## 0. 결정 사항 (사용자 선택)

| 항목 | 선택 | 비고 |
|---|---|---|
| 로컬 K8s | **minikube** | Docker driver 사용 |
| 샘플 앱 | **Node.js + Express** | `pino` 로 stdout JSON 로그 |
| GitOps 소스 | **GitHub 퍼블릭 레포** | ArgoCD 가 폴링 |
| 로그 스택 | **Helm: `grafana/loki` + `grafana/promtail` 개별 차트** | Grafana 는 `grafana/grafana` 개별 설치 |

## 1. 가정 (Assumptions)

- Windows 11 + Docker Desktop(29.x) 정상 동작, WSL2 백엔드.
- `helm` v4.2, `kubectl` v1.36, `node` v24 설치 확인됨. **`minikube` 는 미설치 → 1단계에서 설치.**
- minikube 프로필에 최소 **CPU 4 / MEM 6GB / DISK 40GB** 할당 가능.
- GitHub 계정 보유, 퍼블릭 레포 생성 권한 있음.
- 목표는 **학습/기능 검증**이며 HA·보안 하드닝·영속 스토리지 튜닝은 범위 밖.
- Loki 는 단일 바이너리(SingleBinary) 모드, 스토리지는 filesystem (로컬 PV).

## 2. 목표 아키텍처

```
                         GitHub 레포 (k8s manifests / helm values)
                                   │  (polling, 3분)
                                   ▼
   ┌──────────────────────── minikube 클러스터 ────────────────────────┐
   │                                                                  │
   │   argocd ns ── ArgoCD ──(sync)──► sample-app ns ── sample-app     │
   │                                        │  (stdout JSON 로그)      │
   │                                        ▼                          │
   │   logging ns ── Promtail (DaemonSet) ──push──► Loki (SingleBinary)│
   │                                                   ▲               │
   │   monitoring ns ── Grafana ───────────query───────┘               │
   │                       │                                          │
   └───────────────────────┼──────────────────────────────────────────┘
                           ▼
                    localhost (port-forward / minikube service)
```

네임스페이스: `argocd`, `sample-app`, `logging`, `monitoring`.

## 3. 디렉터리 구조

```
D:\AI_Work\kube-test\
├── PLAN.md                         # 이 문서
├── app\                            # 샘플 애플리케이션 (로컬 빌드)
│   ├── src\server.js
│   ├── package.json
│   └── Dockerfile
├── deploy\                         # GitHub 에 push 할 매니페스트 (ArgoCD 소스)
│   ├── sample-app\
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── argocd\
│       └── application.yaml        # ArgoCD Application CR
├── infra\                          # 관측성 스택 Helm values (로컬 설치용, GitOps 아님)
│   ├── loki-values.yaml
│   ├── promtail-values.yaml
│   └── grafana-values.yaml
└── scripts\
    ├── 00-setup-minikube.ps1
    ├── 01-install-observability.ps1
    ├── 02-install-argocd.ps1
    ├── 03-build-load-image.ps1
    └── 99-teardown.ps1
```

> `infra/` 스택은 학습 편의상 Helm 으로 직접 설치한다. 원하면 이후 단계에서 ArgoCD 관리로 옮긴다(9절).

---

## 4. 단계별 실행 계획 + 검증 기준

각 단계는 **검증 기준(✅)** 을 통과해야 다음으로 넘어간다.

### Step 1 — minikube 기동

작업:
- `winget install Kubernetes.minikube` (또는 choco).
- `minikube start --driver=docker --cpus=4 --memory=6144 --disk-size=40g --profile kube-test`
- `minikube addons enable metrics-server`

✅ 검증:
- `kubectl get nodes` → `Ready`
- `kubectl get pods -A` → 전부 `Running`

### Step 2 — 샘플 앱 작성 & 이미지 빌드

작업:
- `app/src/server.js`: Express 서버.
  - `GET /health` → `{status:"ok"}`
  - `GET /work?ms=NNN` → 지연 후 응답, 처리 로그 남김
  - `GET /error` → 의도적 500 + `level:"error"` 로그
  - 1초마다 heartbeat 로그(옵션, env `HEARTBEAT=true`)
  - 로그는 `pino` 로 **stdout 에 JSON 한 줄**: `{level, time, msg, method, path, status, latency_ms, trace_id}`
- `Dockerfile`: `node:24-alpine`, non-root, `EXPOSE 3000`.
- 빌드: `minikube -p kube-test image build -t sample-app:0.1.0 ./app`
  - 또는 `docker build` 후 `minikube image load sample-app:0.1.0`

✅ 검증:
- `minikube -p kube-test image ls | grep sample-app`
- 로컬에서 `docker run -p 3000:3000 sample-app:0.1.0` 후 `curl localhost:3000/health` → 200, stdout 에 JSON 로그 확인

### Step 3 — 관측성 스택 설치 (Helm, 개별 차트)

작업:
```
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create ns logging
kubectl create ns monitoring

# Loki - SingleBinary + filesystem
helm upgrade --install loki grafana/loki -n logging -f infra/loki-values.yaml

# Promtail - DaemonSet, Loki push URL 지정
helm upgrade --install promtail grafana/promtail -n logging -f infra/promtail-values.yaml

# Grafana - Loki 데이터소스 프로비저닝
helm upgrade --install grafana grafana/grafana -n monitoring -f infra/grafana-values.yaml
```

핵심 values 요지:
- `loki-values.yaml`: `deploymentMode: SingleBinary`, `loki.commonConfig.replication_factor: 1`,
  `loki.storage.type: filesystem`, `singleBinary.replicas: 1`, `loki.auth_enabled: false`,
  `loki.schemaConfig` 는 tsdb + v13.
- `promtail-values.yaml`: `config.clients[0].url: http://loki.logging.svc.cluster.local:3100/loki/api/v1/push`,
  기본 `kubernetes-pods` scrape config 유지(파드 stdout 수집).
- `grafana-values.yaml`: `adminPassword: admin`, `datasources` 에 Loki(`http://loki.logging.svc.cluster.local:3100`) 프로비저닝, `service.type: ClusterIP`.

✅ 검증:
- `kubectl -n logging get pods` → loki, promtail(노드 수만큼) `Running`
- `kubectl -n logging port-forward svc/loki 3100:3100` 후
  `curl "http://localhost:3100/ready"` → `ready`
- `curl "http://localhost:3100/loki/api/v1/labels"` → `job`, `namespace` 등 라벨 반환(클러스터 기존 파드 로그가 이미 수집됨)

### Step 4 — 샘플 앱 배포 (우선 kubectl 로 수동, GitOps 전 검증)

작업:
- `deploy/sample-app/deployment.yaml`: `image: sample-app:0.1.0`, `imagePullPolicy: IfNotPresent`,
  replicas 2, resources requests/limits, liveness/readiness = `/health`.
- `kubectl create ns sample-app`
- `kubectl -n sample-app apply -k deploy/sample-app`

✅ 검증:
- `kubectl -n sample-app get pods` → 2/2 `Running`
- `kubectl -n sample-app port-forward svc/sample-app 8080:80` 후 트래픽 생성:
  - `curl localhost:8080/health`, `curl "localhost:8080/work?ms=200"`, `curl localhost:8080/error`
- `kubectl -n sample-app logs deploy/sample-app` → JSON 로그 출력

### Step 5 — Loki 에서 샘플 앱 로그 조회

작업:
- Grafana 접속: `kubectl -n monitoring port-forward svc/grafana 3000:80` → http://localhost:3000 (admin/admin)
- Explore → Loki 데이터소스.

✅ 검증 (LogQL):
- `{namespace="sample-app"}` → 로그 스트림 표시
- `{namespace="sample-app"} | json | level="error"` → `/error` 호출 건만 필터
- `{namespace="sample-app"} | json | latency_ms > 100` → 파싱된 필드 쿼리 동작
- `sum(rate({namespace="sample-app"} | json | level="error" [5m]))` → 메트릭 쿼리 동작

### Step 6 — ArgoCD 설치

작업:
```
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
# 초기 admin 비번
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8081:443
```
- UI: https://localhost:8081 (admin / 위 비번). 또는 `argocd` CLI 로그인.

✅ 검증:
- `kubectl -n argocd get pods` → 전부 `Running`
- ArgoCD UI 로그인 성공

### Step 7 — GitHub 레포 준비 & GitOps 연결

작업:
- GitHub 퍼블릭 레포 생성 (예: `kube-test-gitops`).
- `deploy/` 하위(`sample-app/`, `argocd/`)를 레포에 push.
- `deploy/argocd/application.yaml` (ArgoCD `Application`):
  - `source.repoURL: https://github.com/<user>/kube-test-gitops`
  - `source.path: sample-app`
  - `source.targetRevision: main`
  - `destination.namespace: sample-app`, `destination.server: https://kubernetes.default.svc`
  - `syncPolicy.automated: { prune: true, selfHeal: true }`
- `kubectl apply -f deploy/argocd/application.yaml`
- Step 4 에서 수동 적용한 리소스는 ArgoCD 가 인수(Adopt)하도록 라벨 정리 or 삭제 후 재싱크.

✅ 검증:
- ArgoCD UI 에서 `sample-app` Application → `Synced` + `Healthy`
- `kubectl -n sample-app get deploy sample-app -o jsonpath="{.metadata.labels}"` → `argocd.argoproj.io/instance` 라벨 존재

### Step 8 — GitOps 루프 E2E 검증

작업 (검증 시나리오):
1. **이미지 태그 변경**: 앱 코드에 로그 필드 추가 → `sample-app:0.2.0` 빌드 & `minikube image load`.
2. 레포에서 `deploy/sample-app/deployment.yaml` 의 이미지 태그 `0.1.0 → 0.2.0` 로 커밋/푸시.
3. ArgoCD 가 감지(수동 `Refresh` 또는 최대 3분 대기) → 자동 Sync → 롤링 업데이트.
4. **self-heal 검증**: `kubectl -n sample-app scale deploy/sample-app --replicas=5` → ArgoCD 가 2로 되돌림.
5. **prune 검증**: 레포에서 `service.yaml` 삭제 후 푸시 → 클러스터에서도 Service 삭제됨.

✅ 검증:
- 새 파드가 `0.2.0` 이미지로 뜨고, 새 로그 필드가 Grafana/Loki 에서 조회됨
- self-heal: replicas 가 자동으로 2 복귀
- prune: 삭제한 리소스가 클러스터에서 사라짐
- ArgoCD Application 이력에 각 Sync 리비전 기록

### Step 9 (선택) — 관측성 스택도 ArgoCD 로 관리

- `deploy/argocd/` 에 Loki/Promtail/Grafana 용 `Application`(Helm source, `helm.values` 인라인 or values 파일) 추가.
- "App of Apps" 패턴으로 루트 Application 하나가 전체를 관리.

✅ 검증: `infra/*-values.yaml` 수정 → 커밋 → ArgoCD 가 Helm 릴리스 업그레이드.

---

## 5. 트러블슈팅 체크리스트

| 증상 | 확인 |
|---|---|
| Promtail 이 로그를 안 보냄 | `kubectl -n logging logs ds/promtail` / clients URL / Loki `/ready` |
| Loki `/ready` 가 계속 not ready | schemaConfig 불일치, PVC pending (`kubectl -n logging get pvc`) |
| Grafana 에서 Loki "no data" | 데이터소스 URL, 시간 범위, 파드 label(`namespace`) 확인 |
| ArgoCD `OutOfSync` 무한 | 수동 적용 리소스와 충돌 → `kubectl delete` 후 재싱크, 또는 `Replace=true` |
| ArgoCD 가 이미지 못 당김 | `imagePullPolicy: IfNotPresent` + `minikube image load` 했는지 |
| minikube 이미지 빌드 후 클러스터에 없음 | `minikube -p kube-test image ls` / 프로필 불일치 |
| 파드 `ImagePullBackOff` | 로컬 이미지 태그 오타, `Never`/`IfNotPresent` 아닌 `Always` |

## 6. 정리 (Teardown)

```
kubectl delete -f deploy/argocd/application.yaml
helm -n logging uninstall loki promtail
helm -n monitoring uninstall grafana
kubectl delete ns argocd sample-app logging monitoring
minikube -p kube-test delete
```

## 7. 예상 소요 시간

| 단계 | 시간 |
|---|---|
| Step 1–2 (minikube + 앱/이미지) | 30–45분 |
| Step 3–5 (관측성 + 로그 확인) | 45–60분 |
| Step 6–8 (ArgoCD + GitOps E2E) | 45–60분 |
| Step 9 (선택) | 30분 |

## 8. 다음 액션

1. 이 계획 리뷰 & 확정.
2. `scripts/00-setup-minikube.ps1` 부터 순서대로 생성/실행.
3. Step 별 ✅ 검증 통과 시마다 진행.
