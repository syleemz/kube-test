# 로컬 K8s 관측성 + GitOps 테스트 계획 (kind 버전)

[PLAN.md](PLAN.md) 의 minikube 대신 **kind (Kubernetes in Docker)** 로 구성하는 버전.
샘플 앱 / Loki / Promtail / Grafana / ArgoCD 구성은 동일하며, **클러스터 생성·이미지 로드·인그레스 부분만 다르다.**

---

## 0. 결정 사항

| 항목 | 선택 | 비고 |
|---|---|---|
| 로컬 K8s | **kind** | 컨트롤플레인 1 + 워커 2 (멀티노드 → Promtail DaemonSet 검증에 유리) |
| 샘플 앱 | **Node.js + Express** | `pino` stdout JSON 로그 |
| GitOps 소스 | **GitHub 퍼블릭 레포** | ArgoCD 폴링 |
| 로그 스택 | **Helm: `grafana/loki` + `grafana/promtail` 개별 차트** | Grafana 개별 설치 |
| 외부 접근 | **ingress-nginx (kind용) + extraPortMappings** | port-forward 대신 `*.localhost` 호스트로 접근 |

## 1. minikube 버전과의 차이 요약

| 구분 | minikube | **kind** |
|---|---|---|
| 클러스터 생성 | `minikube start ...` | `kind create cluster --config kind-config.yaml` |
| 노드 수 | 기본 1 | config 로 3노드(1 CP + 2 worker) |
| 로컬 이미지 주입 | `minikube image load` / `minikube image build` | **`kind load docker-image sample-app:0.1.0 --name kube-test`** |
| 인그레스 | `minikube addons enable ingress` | ingress-nginx `kind` 매니페스트 + config 의 `extraPortMappings`(80/443) + 노드 라벨 |
| 메트릭 서버 | `minikube addons enable metrics-server` | `helm`/매니페스트로 직접 설치 (`--kubelet-insecure-tls` 필요) |
| LoadBalancer | `minikube tunnel` | 미지원(선택: `cloud-provider-kind`) → 여기선 ingress 로 대체 |
| 서비스 접근 | `minikube service` / port-forward | `http://argocd.localhost`, `http://grafana.localhost` 등 |
| 삭제 | `minikube delete` | `kind delete cluster --name kube-test` |

> `deploy/`(ArgoCD 소스), `infra/*-values.yaml`, `app/` 코드, LogQL 검증, GitOps E2E 시나리오는
> [PLAN.md](PLAN.md) 의 Step 2, 3(values), 5, 8 과 **완전히 동일**하므로 여기서는 재기술하지 않고 참조한다.

## 2. 가정

- Docker Desktop(29.x) / WSL2 정상. Docker 에 **CPU 4+ / MEM 8GB+** 할당 (3노드 + 스택 고려).
- `helm` v4.2, `kubectl` v1.36, `node` v24 확인됨. **`kind` 미설치 → Step 1 에서 설치.**
- 80/443 로컬 포트가 비어 있어야 함(ingress extraPortMappings). 사용 중이면 8080/8443 으로 매핑.
- 목표는 학습/기능 검증. HA·보안 하드닝 범위 밖.

## 3. 목표 아키텍처

```
                 GitHub 레포 (deploy/ manifests)  ──polling(3분)──┐
                                                                  ▼
  ┌──────────────────── kind 클러스터 (kube-test) ─────────────────────────┐
  │  node: control-plane          node: worker1        node: worker2       │
  │  ├ ingress-nginx              ├ promtail (DS)       ├ promtail (DS)     │
  │  ├ argocd ns / ArgoCD         ├ sample-app pod      ├ sample-app pod    │
  │  ├ logging ns / Loki(SB)      │                     │                   │
  │  └ monitoring ns / Grafana    └ promtail (DS on CP) │                   │
  │           ▲  push                      │ scrape stdout                  │
  │           └───────────────── Promtail ─┘                                │
  └───────────────────────────────┬───────────────────────────────────────┘
                                  ▼  extraPortMappings 80/443
        http://grafana.localhost  http://argocd.localhost  http://app.localhost
```

## 4. 추가/변경되는 파일

```
d:\AI_Work\kube-test\
├── PLAN.md                      # minikube 버전
├── PLAN-kind.md                 # 이 문서
├── kind-config.yaml             # ★ kind 클러스터 정의 (신규)
├── app\ ...                     # PLAN.md 와 동일
├── deploy\
│   ├── sample-app\
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml         # ★ app.localhost 용 (신규)
│   │   └── kustomization.yaml
│   └── argocd\application.yaml
├── infra\
│   ├── loki-values.yaml         # PLAN.md 와 동일
│   ├── promtail-values.yaml     # 동일
│   └── grafana-values.yaml      # service.type ClusterIP + ingress: grafana.localhost 추가
└── scripts\
    ├── 00-setup-kind.ps1        # ★ (신규, minikube 스크립트 대체)
    ├── 01-install-observability.ps1
    ├── 02-install-argocd.ps1    # argocd.localhost ingress 포함
    ├── 03-build-load-image.ps1  # kind load docker-image
    └── 99-teardown.ps1          # kind delete cluster
```

### `kind-config.yaml` 요지

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kube-test
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80,  hostPort: 80,  protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
  - role: worker
  - role: worker
```

---

## 5. 단계별 계획 + 검증 기준

### Step 1 — kind 설치 & 클러스터 생성

작업:
- 설치: `winget install Kubernetes.kind` (또는 `choco install kind`, 또는 GitHub release 바이너리).
- `kind create cluster --config kind-config.yaml`
- `kubectl config use-context kind-kube-test`

✅ 검증:
- `kubectl get nodes` → 3개 노드 `Ready` (control-plane 1, worker 2)
- `kubectl get pods -A` → CoreDNS, kindnet, kube-proxy 등 `Running`

### Step 2 — ingress-nginx (kind) 설치

작업:
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=available deploy/ingress-nginx-controller --timeout=180s
```

✅ 검증:
- `kubectl -n ingress-nginx get pods` → controller `Running`
- `curl -I http://localhost` → `404` (nginx 응답) = 포트 매핑 정상

### Step 3 — metrics-server (선택)

작업:
```
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --set "args={--kubelet-insecure-tls}"
```

✅ 검증: `kubectl top nodes` → 수치 출력 (몇 분 소요)

### Step 4 — 샘플 앱 빌드 & kind 로 로드

작업:
- 앱 코드/Dockerfile 은 [PLAN.md](PLAN.md) Step 2 와 동일.
- `docker build -t sample-app:0.1.0 ./app`
- **`kind load docker-image sample-app:0.1.0 --name kube-test`**

✅ 검증:
- `docker exec kube-test-worker crictl images | grep sample-app` → 워커 노드에 이미지 존재
- `docker run --rm -p 3000:3000 sample-app:0.1.0` → `/health` 200, stdout JSON 로그

### Step 5 — 관측성 스택 설치

작업: [PLAN.md](PLAN.md) Step 3 과 동일 (`helm upgrade --install` loki / promtail / grafana).
- 차이: `grafana-values.yaml` 에 ingress 추가
  ```yaml
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts: ["grafana.localhost"]
  ```

✅ 검증:
- `kubectl -n logging get pods` → loki 1, **promtail 3개(노드마다 1개)** `Running`
- `curl http://grafana.localhost` → Grafana 로그인 페이지
- Loki: `kubectl -n logging port-forward svc/loki 3100:3100` → `curl localhost:3100/ready` = `ready`

### Step 6 — 샘플 앱 배포 (수동, GitOps 전 검증)

작업:
- `deploy/sample-app/` : deployment(replicas 2) + service + **ingress(`app.localhost`)** + kustomization.
- `kubectl create ns sample-app && kubectl -n sample-app apply -k deploy/sample-app`

✅ 검증:
- `kubectl -n sample-app get pods -o wide` → 2 파드가 **서로 다른 worker 노드**에 스케줄
- `curl http://app.localhost/health` → 200
- 트래픽 생성: `curl "http://app.localhost/work?ms=200"`, `curl http://app.localhost/error`

### Step 7 — Loki 로그 조회

작업/검증: [PLAN.md](PLAN.md) Step 5 와 동일. Grafana 는 `http://grafana.localhost` 로 접근.

✅ 검증 (LogQL):
- `{namespace="sample-app"}` → 스트림 표시
- `{namespace="sample-app"} | json | level="error"` → `/error` 건만
- 로그 라인의 `node_name` 라벨이 worker1/worker2 로 갈림 (멀티노드 수집 확인)

### Step 8 — ArgoCD 설치

작업:
```
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```
- ingress (`argocd.localhost`): ArgoCD 는 자체 TLS 종료 → nginx 에 `backend-protocol: HTTPS` 어노테이션,
  또는 `--insecure` 로 argocd-server 기동(`configmap argocd-cmd-params-cm: server.insecure=true` 후 재시작).
- 초기 비번: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

✅ 검증:
- `kubectl -n argocd get pods` → 전부 `Running`
- `http://argocd.localhost` (또는 port-forward) 로그인 성공

### Step 9 — GitHub 레포 + GitOps 연결

작업/검증: [PLAN.md](PLAN.md) Step 7 과 동일.
- `deploy/argocd/application.yaml` 의 `source.path: sample-app`, `syncPolicy.automated.{prune,selfHeal}: true`.
- `deploy/` 를 GitHub 퍼블릭 레포에 push → `kubectl apply -f deploy/argocd/application.yaml`.

✅ 검증: ArgoCD UI 에서 `sample-app` → `Synced` + `Healthy`.

### Step 10 — GitOps E2E 검증

작업/검증: [PLAN.md](PLAN.md) Step 8 과 동일. 단 이미지 재빌드 시:
- `docker build -t sample-app:0.2.0 ./app` → **`kind load docker-image sample-app:0.2.0 --name kube-test`**
- 레포에서 태그 `0.1.0 → 0.2.0` 커밋/푸시 → ArgoCD Sync → 롤링 업데이트.

✅ 검증:
- 새 파드가 `0.2.0` 로 기동, 새 로그 필드가 Loki 에서 조회
- self-heal: `kubectl -n sample-app scale deploy/sample-app --replicas=5` → 2 로 복귀
- prune: 레포에서 `service.yaml` 삭제 → 클러스터에서도 삭제

### Step 11 (선택) — App of Apps

[PLAN.md](PLAN.md) Step 9 와 동일: 관측성 스택도 ArgoCD Helm Application 으로 관리.

---

## 6. kind 특화 트러블슈팅

| 증상 | 확인 |
|---|---|
| 파드 `ImagePullBackOff` (로컬 이미지) | `kind load docker-image` 를 **해당 클러스터 이름(`--name kube-test`)** 으로 했는지 / `imagePullPolicy: IfNotPresent` |
| `kind load` 후에도 이미지 없음 | 새 노드 추가 시 재로드 필요 / `docker exec kube-test-worker crictl images` |
| `curl http://*.localhost` 연결 거부 | `kind-config.yaml` 의 `extraPortMappings` 반영됐는지(클러스터 재생성 필요) / 80·443 포트 선점 |
| ingress 404 (nginx 는 뜸) | Ingress 리소스의 `ingressClassName: nginx`, host 오타, `ingress-ready=true` 노드 라벨 |
| ArgoCD ingress 502/리다이렉트 루프 | `server.insecure=true` 미적용 또는 nginx `backend-protocol` 어노테이션 누락 |
| `kubectl top` 실패 | metrics-server `--kubelet-insecure-tls` 인자 누락 |
| 클러스터가 무겁고 느림 | Docker Desktop 메모리 8GB+ / 워커 1개로 축소 |
| Loki PVC `Pending` | kind 기본 `standard` SC(local-path) 동작 확인: `kubectl get sc` |

## 7. 정리 (Teardown)

```
kubectl delete -f deploy/argocd/application.yaml
helm -n logging uninstall loki promtail
helm -n monitoring uninstall grafana
kind delete cluster --name kube-test
```

## 8. 예상 소요 시간

| 단계 | 시간 |
|---|---|
| Step 1–4 (kind + ingress + 앱 이미지) | 30–45분 |
| Step 5–7 (관측성 + 로그 확인) | 45–60분 |
| Step 8–10 (ArgoCD + GitOps E2E) | 45–60분 |
| Step 11 (선택) | 30분 |

## 9. 다음 액션

1. 이 계획 확정.
2. `kind-config.yaml` + `scripts/00-setup-kind.ps1` 생성/실행.
3. 이후 `app/`, `deploy/`, `infra/` 는 [PLAN.md](PLAN.md) 와 공유. Step 별 ✅ 검증 통과 시 진행.
