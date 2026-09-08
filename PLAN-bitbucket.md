# GitOps 소스로 Bitbucket 사용하기 (참조)

[PLAN.md](PLAN.md) / [PLAN-kind.md](PLAN-kind.md) / [PLAN-rancher.md](PLAN-rancher.md) 의 **Step 7 (GitHub 레포 + GitOps 연결)** 을
Bitbucket 으로 대체할 때만 참고하는 문서. 나머지 단계는 변경 없음.

---

## 0. 무엇이 바뀌나

| 구분 | GitHub (원 계획) | **Bitbucket** |
|---|---|---|
| `Application.spec.source.repoURL` | `https://github.com/<user>/<repo>` | Cloud: `https://bitbucket.org/<workspace>/<repo>.git` <br> DC/Server: `https://<host>/scm/<project>/<repo>.git` |
| 프라이빗 레포 인증 | Personal Access Token (PAT) | **Repository/Workspace Access Token** 또는 **App Password** (계정 비밀번호 불가) |
| HTTPS username | GitHub username | Access Token → `x-token-auth` / App Password → 실제 username |
| 웹훅 시크릿 키 (argocd-secret) | `webhook.github.secret` | Cloud: `webhook.bitbucket.secret` <br> DC/Server: `webhook.bitbucketserver.secret` |
| `path`, `targetRevision`, `syncPolicy` | — | **동일 (변경 없음)** |

## 1. 퍼블릭 레포 → GitHub와 동일

Bitbucket Cloud 퍼블릭 레포면 자격증명 불필요. `repoURL` 형식만 교체:

```yaml
# deploy/argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://bitbucket.org/<workspace>/<repo>.git
    path: sample-app
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: sample-app
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

## 2. 프라이빗 레포 → 자격증명 등록

### 2-1. 토큰 발급 (택1)

| 방식 | 발급 위치 | 스코프 | 비고 |
|---|---|---|---|
| **Repository Access Token** (권장) | 레포 → Settings → Access tokens | `repository:read` | 범위 최소, 레포 단위 |
| Workspace/Project Access Token | Workspace/Project settings → Access tokens | `repository:read` | 여러 레포 공용 시 |
| App Password | 개인 → Personal settings → App passwords | `Repositories: Read` | 계정 전체 범위(차선) |
| SSH Deploy Key | 레포 → Settings → Access keys | 읽기 전용 | SSH 선호 시 |

### 2-2. ArgoCD 등록 — CLI

```bash
# Access Token 사용
argocd repo add https://bitbucket.org/<workspace>/<repo>.git \
  --username x-token-auth --password <access-token>

# App Password 사용
argocd repo add https://bitbucket.org/<workspace>/<repo>.git \
  --username <bitbucket-username> --password <app-password>
```

### 2-3. ArgoCD 등록 — Secret 매니페스트

`deploy/argocd/repo-secret.yaml` (⚠️ **GitOps 레포에 커밋 금지** — 로컬에서 `kubectl apply` 만):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bitbucket-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://bitbucket.org/<workspace>/<repo>.git
  username: x-token-auth          # App Password면 실제 username
  password: <access-token>
```

```bash
kubectl apply -f deploy/argocd/repo-secret.yaml
```

### 2-4. SSH 방식 (대안)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bitbucket-gitops-repo-ssh
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@bitbucket.org:<workspace>/<repo>.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
```
공개키는 레포 Settings → Access keys 에 등록.

## 3. Bitbucket Data Center / Server 인 경우

- `repoURL`: `https://<host>/scm/<project>/<repo>.git` (프로젝트 키는 대문자)
- 인증: **HTTP access token** (Repository/Project 단위) 또는 username/password
  ```yaml
  stringData:
    type: git
    url: https://bitbucket.example.com/scm/PROJ/repo.git
    username: <username>
    password: <http-access-token>
  ```
- 사설 CA/자체서명 인증서면 `argocd-tls-certs-cm` ConfigMap 에 CA 추가 또는 `insecure: "true"` (학습용).

## 4. 즉시 동기화(웹훅) — 로컬에선 생략 권장

- 로컬 클러스터는 인터넷에서 도달 불가 → Bitbucket 웹훅이 ArgoCD 로 못 옴.
- **기본 3분 폴링 유지**. 즉시 반영이 필요하면 ArgoCD UI `Refresh` 또는 `argocd app sync sample-app`.
- 굳이 하려면 `cloudflared` / `ngrok` 로 `argocd-server` 를 외부 노출 후:
  - Bitbucket Cloud: Repo → Settings → Webhooks, URL `https://<tunnel>/api/webhook`, Trigger `Repository push`
  - `argocd-secret` 에 `webhook.bitbucket.secret` (Cloud) / `webhook.bitbucketserver.secret` (DC) 키 추가

## 5. 트러블슈팅

| 증상 | 확인 |
|---|---|
| `authentication required` / `403` | 계정 비밀번호를 넣었을 가능성 → Access Token / App Password 로 교체 |
| Access Token 인데 `401` | username 이 `x-token-auth` 인지 (App Password는 실제 username) |
| `repository not found` | `repoURL` 끝에 `.git`, workspace/project 슬러그 대소문자 |
| App Password 스코프 부족 | `Repositories: Read` 체크 여부 |
| DC/Server TLS 오류 | `argocd-tls-certs-cm` 에 CA 등록 또는 repo `insecure: true` |
| 여러 레포 공용 인증 | Secret 대신 `argocd.argoproj.io/secret-type: repo-creds` + `url` 을 `https://bitbucket.org/<workspace>` 프리픽스로 |

## 6. 계획 반영 메모

세 계획서의 Step 7 에서:
- "GitHub 퍼블릭 레포" → "Bitbucket 레포 (형식은 이 문서 0절)"
- 프라이빗이면 Step 7 앞에 **2-3 의 `repo-secret.yaml` apply** 를 선행
- `deploy/argocd/application.yaml` 의 `repoURL` 만 교체, 그 외 필드 동일
