# 로컬 K8s 관측성 + GitOps 테스트 계획 (Rancher Desktop / 내장 k3s 버전)

[PLAN.md](PLAN.md)(minikube), [PLAN-kind.md](PLAN-kind.md)(kind)의 3번째 변형.
별도 로컬 클러스터 도구를 설치하지 않고 **Rancher Desktop 내장 Kubernetes(k3s)** 를 그대로 사용한다.
샘플 앱 / Loki / Promtail / Grafana / ArgoCD 구성과 검증 시나리오는 [PLAN.md](PLAN.md)와 공유하며,
**클러스터 기동 · 이미지 빌드 · 노출(Ingress/LoadBalancer)** 부분만 다르다.

---

## 0. 결정 사항

| 항목 | 선택 | 비고 |
|---|---|---|
| 로컬 K8s | **Rancher Desktop 내장 k3s** | 단일 노드. 추가 설치 없음 |
| 컨테이너 엔진 | **containerd (nerdctl)** | `nerdctl --namespace k8s.io build` → k3s가 이미지 즉시 인식 (load 단계 불필요) |
| 샘플 앱 | **Node.js + Express** | `pino` stdout JSON 로그 |
| GitOps 소스 | **GitHub 퍼블릭 레포** | ArgoCD 폴링 |
| 로그 스택 | **Helm: `grafana/loki` + `grafana/promtail` 개별 차트** | Grafana 개별 설치 |
| 외부 접근 | **내장 Traefik Ingress + `*.localhost` 호스트** | k3s Traefik이 이미 80/443 점유(klipper ServiceLB) |

## 1. minikube / kind 버전과의 차이 요약

| 구분 | minikube | kind | **Rancher Desktop k3s** |
|---|---|---|---|
| 클러스터 생성 | `minikube start` | `kind create cluster` | **Rancher Desktop 설정에서 Kubernetes 토글 ON** |
| 노드 수 | 1 | 1 CP + 2 worker | **1 (단일 노드)** |
| 로컬 이미지 주입 | `minikube image load` | `kind load docker-image` | **`nerdctl --namespace k8s.io build -t ...` → 별도 로드 없음** |
| Ingress 컨트롤러 | addon(nginx) | kind용 nginx 매니페스트 | **Traefik 기본 탑재** (kube-system) |
| LoadBalancer Service | `minikube tunnel` 필요 | 미지원 | **klipper ServiceLB 기본 동작** (EXTERNAL-IP = 127.0.0.1) |
| metrics-server | addon | 직접 설치 | **k3s 기본 포함** |
| StorageClass | 기본 | `standard`(local-path) | **`local-path` 기본** |
| 삭제/초기화 | `minikube delete` | `kind delete cluster` | **Rancher Desktop: Troubleshooting → Reset Kubernetes** |

> `app/` 코드, `deploy/`(ArgoCD 소스), `infra/*-values.yaml`, LogQL 검증, GitOps E2E 시나리오는
> [PLAN.md](PLAN.md)의 Step 2·3·5·8과 **동일**하므로 여기서는 참조만 한다.

## 2. 가정

- Rancher Desktop 설치·실행 중, **Preferences → Kubernetes: Enabled**, 컨테이너 엔진 = **containerd**.
  (dockerd 를 쓰는 경우는 6절 참고 — 이미지 워크플로우만 달라짐)
- Rancher Desktop VM 리소스: **CPU 4+ / MEM 8GB+** (k3s + Loki/Grafana/ArgoCD 동시 구동).
- `helm` v4.2, `kubectl` v1.36, `node` v24, `nerdctl`(Rancher Desktop 동봉) 사용 가능.
- 로컬 80/443 포트는 Traefik(k3s)이 사용. 이미 다른 프로세스가 선점 중이면 **80/443 을 안 써도 됨** → 7-A 절(대체 포트) 참고.
- `*.localhost` 가 127.0.0.1 로 해석됨(대부분 OS 기본). 안 되면 `hosts` 파일에 추가.
- 목표는 학습/기능 검증. HA·보안 하드닝 범위 밖.
- Loki 는 SingleBinary + filesystem 스토리지.

## 3. 목표 아키텍처

```
              GitHub 레포 (deploy/ manifests) ──polling(3분)──┐
                                                              ▼
  ┌──────────── Rancher Desktop VM / k3s (단일 노드) ─────────────────┐
  │  kube-system:  Traefik(Ingress, :80/:443)  ·  metrics-server      │
  │  argocd:       ArgoCD           ──sync──►  sample-app: 앱 파드 x2  │
  │  logging:      Loki(SingleBinary) ◄─push─  Promtail(DaemonSet x1)  │
  │  monitoring:   Grafana ──query──► Loki                            │
  └───────────────────────────┬─────────────────────────────────────┘
                              ▼  Traefik Ingress
     http://grafana.localhost   http://argocd.localhost   http://app.localhost
```

네임스페이스: `argocd`, `sample-app`, `logging`, `monitoring`.

## 4. 디렉터리 구조 (kind 버전과 거의 동일)

```
d:\AI_Work\kube-test\
├── PLAN.md · PLAN-kind.md · PLAN-rancher.md
├── app\ ...                         # PLAN.md 와 동일 (src/server.js, package.json, Dockerfile)
├── deploy\
│   ├── sample-app\
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml             # app.localhost (Traefik)
│   │   └── kustomization.yaml
│   └── argocd\application.yaml
├── infra\
│   ├── loki-values.yaml             # PLAN.md 와 동일
│   ├── promtail-values.yaml         # 동일
│   └── grafana-values.yaml          # ingress: grafana.localhost 추가
└── scripts\
    ├── 01-install-observability.ps1
    ├── 02-install-argocd.ps1
    ├── 03-build-image.ps1           # nerdctl --namespace k8s.io build
    └── 99-teardown.ps1
```

> Rancher Desktop 버전은 `00-setup-*` (클러스터 생성) 스크립트가 필요 없다. GUI 토글로 끝.

---

## 5. 단계별 계획 + 검증 기준

### Step 1 — Rancher Desktop Kubernetes 활성화

작업:
- Rancher Desktop → Preferences → Kubernetes → **Enable Kubernetes** (버전은 기본 stable).
- Preferences → Container Engine → **containerd** 확인.
- `kubectl config use-context rancher-desktop`

✅ 검증:
- `kubectl get nodes` → 1개 노드 `Ready` (이름: `lima-rancher-desktop` 또는 유사)
- `kubectl get pods -A` → `kube-system` 의 `traefik-*`, `metrics-server-*`, `local-path-provisioner-*`, `coredns-*` 전부 `Running`
- `kubectl get svc -n kube-system traefik` → `EXTERNAL-IP` 에 `127.0.0.1`
- `kubectl get sc` → `local-path (default)`
- `kubectl top nodes` → 수치 출력 (metrics-server 내장 확인)

### Step 2 — 샘플 앱 빌드 (nerdctl, 로드 단계 없음)

작업:
- 앱 코드 / Dockerfile 은 [PLAN.md](PLAN.md) Step 2 와 동일.
- **`nerdctl --namespace k8s.io build -t sample-app:0.1.0 ./app`**
  - `--namespace k8s.io` 가 핵심: k3s 의 containerd 이미지 스토어에 직접 저장됨.
- 매니페스트에서 `imagePullPolicy: IfNotPresent` (로컬 이미지 사용).

✅ 검증:
- `nerdctl --namespace k8s.io images | grep sample-app` → 이미지 존재
- `sudo k3s crictl images 2>/dev/null | grep sample-app` (선택, VM 내부 확인)
- 로컬 스모크: `nerdctl run --rm -p 3000:3000 sample-app:0.1.0` → `curl localhost:3000/health` 200, stdout JSON 로그

### Step 3 — 관측성 스택 설치 (Helm)

작업: [PLAN.md](PLAN.md) Step 3 과 동일. `helm upgrade --install` 로 loki / promtail / grafana.
- `grafana-values.yaml` 에 Traefik Ingress 추가:
  ```yaml
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts: ["grafana.localhost"]
  service:
    type: ClusterIP
  ```
- `promtail-values.yaml` 의 clients URL: `http://loki.logging.svc.cluster.local:3100/loki/api/v1/push` (동일).

✅ 검증:
- `kubectl -n logging get pods` → loki 1, **promtail 1개(단일 노드)** `Running`
- `curl http://grafana.localhost` → Grafana 로그인 페이지 (Traefik 라우팅 정상)
- `kubectl -n logging port-forward svc/loki 3100:3100` → `curl localhost:3100/ready` = `ready`
- `curl "http://localhost:3100/loki/api/v1/labels"` → `namespace`, `pod` 등 라벨 반환 (k3s 시스템 파드 로그가 이미 수집됨)

### Step 4 — 샘플 앱 배포 (수동, GitOps 전 검증)

작업:
- `deploy/sample-app/` : deployment(replicas 2) + service(ClusterIP) + ingress(`app.localhost`, `ingressClassName: traefik`) + kustomization.
- `kubectl create ns sample-app && kubectl -n sample-app apply -k deploy/sample-app`

✅ 검증:
- `kubectl -n sample-app get pods` → 2/2 `Running`
- `curl http://app.localhost/health` → 200
- 트래픽 생성: `curl "http://app.localhost/work?ms=200"`, `curl http://app.localhost/error`
- `kubectl -n sample-app logs deploy/sample-app` → JSON 로그 출력

### Step 5 — Loki 에서 샘플 앱 로그 조회

작업: Grafana `http://grafana.localhost` (admin / `grafana-values.yaml` 의 adminPassword) → Explore → Loki.
검증 LogQL 은 [PLAN.md](PLAN.md) Step 5 와 동일.

✅ 검증:
- `{namespace="sample-app"}` → 스트림 표시
- `{namespace="sample-app"} | json | level="error"` → `/error` 호출 건만
- `{namespace="sample-app"} | json | latency_ms > 100` → 파싱 필드 쿼리 동작
- `sum(rate({namespace="sample-app"} | json | level="error" [5m]))` → 메트릭 쿼리 동작

### Step 6 — ArgoCD 설치

작업:
```
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```
- Traefik Ingress 로 노출하려면 ArgoCD 서버를 insecure 모드로:
  ```
  kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
  kubectl -n argocd rollout restart deploy/argocd-server
  ```
  그리고 `argocd.localhost` Ingress(`ingressClassName: traefik`) 생성.
- 초기 비번: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- (대안) Ingress 없이 `kubectl -n argocd port-forward svc/argocd-server 8081:443` 사용.

✅ 검증:
- `kubectl -n argocd get pods` → 전부 `Running`
- `http://argocd.localhost` (또는 port-forward) 로그인 성공

### Step 7 — GitHub 레포 + GitOps 연결

작업/검증: [PLAN.md](PLAN.md) Step 7 과 동일.
- GitHub 퍼블릭 레포에 `deploy/` push.
- `deploy/argocd/application.yaml`: `source.path: sample-app`, `destination.server: https://kubernetes.default.svc`,
  `destination.namespace: sample-app`, `syncPolicy.automated: {prune: true, selfHeal: true}`.
- `kubectl apply -f deploy/argocd/application.yaml`.
- Step 4 에서 수동 적용한 리소스는 삭제 후 ArgoCD 가 재생성하도록 하거나 Adopt.

✅ 검증:
- ArgoCD UI 에서 `sample-app` → `Synced` + `Healthy`
- `kubectl -n sample-app get deploy sample-app -o jsonpath="{.metadata.labels}"` → `argocd.argoproj.io/instance` 라벨 존재

### Step 8 — GitOps 루프 E2E 검증

작업/검증: [PLAN.md](PLAN.md) Step 8 과 동일. 단 이미지 재빌드는:
- **`nerdctl --namespace k8s.io build -t sample-app:0.2.0 ./app`** (load 불필요)
- 레포에서 `deploy/sample-app/deployment.yaml` 이미지 태그 `0.1.0 → 0.2.0` 커밋/푸시 → ArgoCD Sync.

✅ 검증:
- 새 파드가 `0.2.0` 로 기동, 새 로그 필드가 Grafana/Loki 에서 조회
- self-heal: `kubectl -n sample-app scale deploy/sample-app --replicas=5` → 2 로 복귀
- prune: 레포에서 `service.yaml` 삭제 → 클러스터에서도 삭제
- ArgoCD Application 이력에 각 Sync 리비전 기록

### Step 9 (선택) — App of Apps

[PLAN.md](PLAN.md) Step 9 와 동일: 관측성 스택도 ArgoCD Helm Application 으로 관리.

---

## 6. 컨테이너 엔진이 dockerd(moby)인 경우

Rancher Desktop 을 dockerd 로 쓰면 `docker build` 이미지가 k3s(containerd)에 **보이지 않는다.** 세 가지 방법:

1. **엔진을 containerd 로 전환** (권장) → Step 2 그대로.
2. **로컬 레지스트리 경유**:
   ```
   docker run -d -p 5000:5000 --name registry registry:2
   docker build -t localhost:5000/sample-app:0.1.0 ./app && docker push localhost:5000/sample-app:0.1.0
   # 매니페스트 image: localhost:5000/sample-app:0.1.0
   ```
   (k3s 가 `localhost:5000` 을 insecure registry 로 인식하도록 `registries.yaml` 설정 필요할 수 있음)
3. **이미지 파일 임포트**: `docker save sample-app:0.1.0 -o img.tar` → `nerdctl --namespace k8s.io load -i img.tar`

## 7. Traefik 대신 ingress-nginx 를 쓰고 싶다면 (EKS 근접용)

- Rancher Desktop: Preferences → Kubernetes → **Traefik 비활성화** (또는 `helm -n kube-system uninstall traefik`).
- `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx`
- `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace --set controller.service.type=LoadBalancer`
  - klipper ServiceLB 가 nginx 컨트롤러에 `127.0.0.1` EXTERNAL-IP 부여 → 80/443 그대로 사용.
- 모든 Ingress 의 `ingressClassName` 을 `nginx` 로 변경.

## 7-A. 80/443 을 쓸 수 없을 때 (대체 포트)

80/443 이 이미 점유돼 있으면 다음 중 하나. 아래로 갈수록 클러스터 설정을 덜 건드린다.

### 방법 1 — Ingress 없이 `kubectl port-forward` (가장 간단, 권장)

Ingress/Traefik 자체를 안 쓰고 서비스별로 임의의 로컬 포트에 포워딩:
```
kubectl -n monitoring port-forward svc/grafana      3000:80
kubectl -n argocd     port-forward svc/argocd-server 8081:443
kubectl -n sample-app port-forward svc/sample-app    8080:80
```
- 접근: `http://localhost:3000`, `https://localhost:8081`, `http://localhost:8080`
- `deploy/sample-app/ingress.yaml`, `grafana-values.yaml` 의 `ingress:` 블록은 만들지 않아도 됨.
- 단점: 터미널 세션이 떠 있어야 함(백그라운드로 돌리거나 `&`).

### 방법 2 — Traefik 은 유지하되 다른 포트로 포워딩

```
kubectl -n kube-system port-forward svc/traefik 8080:80 8443:443
```
- 접근: `http://grafana.localhost:8080`, `http://argocd.localhost:8080` (호스트 라우팅 그대로, 포트만 8080)
- Ingress 리소스는 그대로 두면 됨.

### 방법 3 — Traefik 이 노출하는 포트 자체를 변경 (영구)

k3s 는 Traefik 을 HelmChart 로 배포하므로 `HelmChartConfig` 로 덮어쓴다.
Rancher Desktop VM 안 `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`:
```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        exposedPort: 8000
      websecure:
        exposedPort: 8443
```
- 저장 후 k3s 가 자동 재적용. 접근: `http://grafana.localhost:8000`
- VM 내부 파일 편집이 번거로움(`rdctl shell` 로 진입). 방법 1·2 로 충분하면 불필요.

### 방법 4 — NodePort 로 노출

Ingress 컨트롤러 서비스 또는 각 서비스를 `type: NodePort` 로 바꾸면 `30000–32767` 범위 포트로 접근.
Rancher Desktop 이 NodePort 를 호스트로 자동 포워딩한다. 포트 번호가 고정적이지 않아 학습용으로는 방법 1 이 낫다.

> `*.localhost` 는 포트가 붙어도 127.0.0.1 로 해석되므로 `http://app.localhost:8080` 형태가 그대로 동작한다.

## 8. Rancher Desktop 특화 트러블슈팅

| 증상 | 확인 |
|---|---|
| 파드 `ErrImageNeverPull` / `ImagePullBackOff` | `nerdctl --namespace k8s.io build` 로 빌드했는지 (`--namespace k8s.io` 누락 시 k3s가 못 봄) / `imagePullPolicy` |
| `nerdctl` 명령을 못 찾음 | Rancher Desktop 이 PATH 에 추가한 `~/.rd/bin` 확인, RD 재시작 |
| `curl http://*.localhost` 연결 거부 | Traefik svc `EXTERNAL-IP` 확인 / 80·443 포트 선점(다른 웹서버) / `*.localhost` 해석 실패 시 hosts 등록 |
| Ingress 404 (Traefik 은 응답) | `ingressClassName: traefik`, host 오타 |
| ArgoCD Ingress 502 / 리다이렉트 루프 | `server.insecure=true` 적용 + argocd-server 재시작 했는지 |
| Loki PVC `Pending` | `kubectl get sc` 에 `local-path (default)` 있는지, `local-path-provisioner` 파드 `Running` |
| 전체가 느리고 OOM | Rancher Desktop VM 메모리 8GB+ 로 상향 (Preferences → Virtual Machine) |
| Kubernetes 가 안 뜸 / 꼬임 | Troubleshooting → **Reset Kubernetes** (팩토리 리셋 아님, k3s 만 재생성) |
| `kubectl` 컨텍스트 혼동 | `kubectl config use-context rancher-desktop` |

## 9. 정리 (Teardown)

```
kubectl delete -f deploy/argocd/application.yaml
helm -n logging uninstall loki promtail
helm -n monitoring uninstall grafana
kubectl delete ns argocd sample-app logging monitoring
```
- 클러스터 자체 초기화: Rancher Desktop → Troubleshooting → **Reset Kubernetes**
- 빌드 이미지 정리: `nerdctl --namespace k8s.io rmi sample-app:0.1.0 sample-app:0.2.0`

## 10. 예상 소요 시간

| 단계 | 시간 |
|---|---|
| Step 1–2 (k8s 활성화 + 앱 이미지) | 15–25분 (클러스터 생성 불필요) |
| Step 3–5 (관측성 + 로그 확인) | 45–60분 |
| Step 6–8 (ArgoCD + GitOps E2E) | 45–60분 |
| Step 9 (선택) | 30분 |

## 11. 세 계획 비교 요약

| | [PLAN.md](PLAN.md) (minikube) | [PLAN-kind.md](PLAN-kind.md) (kind) | **PLAN-rancher.md (k3s)** |
|---|---|---|---|
| 추가 설치 | minikube | kind | **없음 (RD 내장)** |
| 노드 | 1 | 3 | 1 |
| 이미지 워크플로우 | `minikube image load` | `kind load docker-image` | **`nerdctl` 빌드 → 로드 불필요** |
| LoadBalancer | tunnel 필요 | 미지원 | **기본 동작 (ServiceLB)** |
| Ingress | nginx addon | nginx(수동) | **Traefik 내장** (nginx 교체 가능) |
| 멀티노드 DaemonSet 검증 | ✗ | ✓ | ✗ |
| 설정 부담 / 속도 | 중 | 높음 | **낮음 / 가장 빠름** |

## 12. 다음 액션

1. 이 계획 확정.
2. Rancher Desktop 에서 Kubernetes 활성화 + 엔진 containerd 확인.
3. `app/` 작성 → `nerdctl --namespace k8s.io build` → `scripts/01`, `02` 순서로.
4. Step 별 ✅ 검증 통과 시 진행. `app/`, `deploy/`, `infra/` 는 [PLAN.md](PLAN.md) 와 공유.
