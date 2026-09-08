# `docker ps` 컨테이너 목록 설명 (2026-09-08 기준)

## 왜 이렇게 많은가

Rancher Desktop 이 **dockerd(moby) 엔진 + cri-dockerd** 로 돌기 때문에,
**k3s 가 띄우는 모든 파드가 `docker ps` 에 그대로 보인다.** 수동으로 `docker run` 한 건 하나도 없다.
(컨테이너 엔진이 containerd 였다면 `docker ps` 엔 안 보이고 `nerdctl -n k8s.io ps` 로 봐야 함)

현재 **실행 중 31개** — 전부 k8s 관리. 파드 1개당 컨테이너 2종류:

| 이름 패턴 | 정체 | 비고 |
|---|---|---|
| `k8s_POD_<pod>_<ns>_...` | **pause(sandbox) 컨테이너** | `rancher/mirrored-pause:3.6`. 파드의 네트워크 네임스페이스만 잡아둠. 리소스 ~0 |
| `k8s_<container>_<pod>_<ns>_...` | **실제 워크로드 컨테이너** | 앱/사이드카 등 |

이름 형식: `k8s_<컨테이너명>_<파드명>_<네임스페이스>_<파드UID>_<재시작횟수>`

---

## 네임스페이스별 (실행 중)

### kube-system — k3s 기본 구성요소 (4시간+ 가동)

| 컨테이너 | 설명 |
|---|---|
| `coredns` | 클러스터 내부 DNS (`*.svc.cluster.local` 해석) |
| `local-path-provisioner` | PVC 요청 시 노드 로컬 디렉터리를 볼륨으로 프로비저닝. 기본 StorageClass `local-path` |
| `metrics-server` | `kubectl top`, HPA 용 CPU/메모리 메트릭 수집 |

### logging — 로그 스택 (이번에 설치, Helm)

| 컨테이너 | 설명 |
|---|---|
| `loki` | 로그 저장·쿼리 엔진. SingleBinary 모드, filesystem 스토리지 (`loki-0`) |
| `loki-sc-rules` | loki-0 안의 사이드카. 룰 ConfigMap 변경을 loki 로 동기화 (지금은 룰 없음) |
| `promtail` | DaemonSet(노드당 1개). `/var/log/pods` 를 tail 해서 loki 로 push. docker JSON 포맷 파싱 |

### monitoring — 시각화 (이번에 설치, Helm)

| 컨테이너 | 설명 |
|---|---|
| `grafana` | 대시보드 / Explore UI. Loki 데이터소스 프로비저닝됨 |

### sample-app — 테스트 대상 앱 (이번에 배포)

| 컨테이너 | 설명 |
|---|---|
| `app` ×2 | 샘플 Express 앱, `replicas: 2`. 이미지 `sample-app:0.1.0` (ID `32ad7df10fcc`). `/health`, `/work`, `/error` + heartbeat 로그 |

### argocd — GitOps (이번에 설치)

| 컨테이너 | 설명 |
|---|---|
| `argocd-server` | API 서버 + 웹 UI (port-forward 8081 로 접근) |
| `argocd-repo-server` | Git 레포 clone, Helm/Kustomize manifest 렌더링 |
| `argocd-application-controller` | 렌더된 manifest ↔ 클러스터 실제 상태 비교·동기화(sync/self-heal/prune). `application-controller-0` StatefulSet |
| `argocd-applicationset-controller` | `ApplicationSet` CRD 처리 (App of Apps 자동 생성). 지금은 미사용 |
| `argocd-notifications-controller` | sync 결과를 Slack/이메일 등으로 알림 |
| `argocd-dex-server` | 외부 SSO/OIDC 연동용 (dex). 로컬 admin 로그인만 쓰면 유휴 |
| `argocd-redis` | UI 응답·매니페스트 캐시 |

---

## 중지된 컨테이너 (참고, `docker ps -a`)

| 컨테이너 | 상태 | 설명 |
|---|---|---|
| `k8s_copyutil_*`, `k8s_secret-init_*` (argocd) | Exited (0) | **init 컨테이너**. 파드 시작 시 1회 실행 후 정상 종료. 재실행 안 됨 = 정상 |
| `k8s_coredns_*_41`, `k8s_*_43` 등 (kube-system) | Exited (255), 4h ago | Rancher Desktop / k3s 재시작으로 교체된 **이전 세대** 컨테이너. 방치 무방, `docker system prune` 로 정리 가능 |
| `rag-redis`, `rag-postgres` | Exited (0), 2주 전 | **kube-test 와 무관.** 다른 프로젝트(RAG) 개발용 컨테이너, 중지 상태 |
| `sql1` (mssql 2019) | Exited (0), 10일 전 | **무관.** 개인 MSSQL 테스트 컨테이너 |
| `oracle11g-4th` | Exited (137), 10일 전 | **무관.** 개인 Oracle XE 컨테이너 (137 = OOM/kill 로 종료된 흔적) |

> 마지막 4개(rag-*, sql1, oracle11g)는 이 프로젝트와 상관없고 오래 방치된 것. 디스크가 필요하면
> `docker rm rag-redis rag-postgres sql1 oracle11g-4th` 로 제거 가능(이미지는 유지됨).

---

## 정리 명령

```powershell
# kube-test 스택만 제거 (k8s 네임스페이스 단위)
./scripts/99-teardown.ps1

# 중지된 옛 세대 k8s 컨테이너 정리 (실행 중인 건 건드리지 않음)
docker container prune -f
```
