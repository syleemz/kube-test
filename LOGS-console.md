# 라이브 K8s 환경에서 콘솔(CLI)로 로그 확인하기 (참조)

운영/스테이징 등 실제 클러스터에서 **터미널만으로** 로그를 확인하는 방법 정리.
크게 두 경로 — ① 파드 stdout 직접(`kubectl logs`, `stern`) ② 수집된 Loki 조회(`logcli`, HTTP API).

---

## 0. 어떤 걸 쓰나

| 상황 | 도구 |
|---|---|
| 지금 떠 있는 특정 파드/디플로이 로그 빠르게 | `kubectl logs` |
| 여러 파드/여러 네임스페이스 실시간 tail | `stern` |
| 이미 종료·회전된 로그, 기간 지정 검색, 필드 필터 | `logcli` (Loki) |
| logcli 설치 불가, 스크립트/CI | `curl` + Loki HTTP API |
| 매니지드(EKS/GKE) 클라우드 로깅 | `aws logs` / `gcloud logging` (6절) |

> `kubectl logs` 는 **컨테이너가 살아있고 로그가 회전되기 전** 것만 본다. 과거 이력·삭제된 파드는 Loki 로.

---

## 1. `kubectl logs` — 파드 stdout 직접

### 기본

```bash
kubectl -n sample-app logs <pod>                     # 단일 파드
kubectl -n sample-app logs deploy/sample-app         # 디플로이(파드 1개 자동 선택)
kubectl -n sample-app logs -l app=sample-app         # 라벨 셀렉터 = 여러 파드
kubectl -n sample-app logs <pod> -c <container>      # 멀티 컨테이너 중 특정
kubectl -n sample-app logs <pod> --all-containers    # 파드 내 전 컨테이너
```

### 실시간 / 범위 / 이전 컨테이너

```bash
kubectl -n sample-app logs -f deploy/sample-app                # follow (tail -f)
kubectl -n sample-app logs deploy/sample-app --tail=200        # 최근 200줄
kubectl -n sample-app logs deploy/sample-app --since=15m       # 최근 15분
kubectl -n sample-app logs deploy/sample-app --since-time=2026-09-08T02:00:00Z
kubectl -n sample-app logs <pod> -p                            # 직전(크래시된) 컨테이너
kubectl -n sample-app logs <pod> --timestamps                  # 각 줄에 타임스탬프
```

### 여러 파드 동시 (kubectl 1.x)

```bash
kubectl -n sample-app logs -l app=sample-app --prefix -f --tail=50 --max-log-requests=10
```
- `--prefix` : 각 줄 앞에 `[pod/이름]` 표시
- `--max-log-requests` : 셀렉터로 잡히는 파드가 많을 때 상한(기본 5)

### CrashLoopBackOff 디버깅 세트

```bash
kubectl -n sample-app get pods
kubectl -n sample-app logs <pod> -p            # 죽기 직전 로그
kubectl -n sample-app describe pod <pod>       # 이벤트/재시작 사유(OOMKilled 등)
kubectl -n sample-app get events --sort-by=.lastTimestamp | tail -30
```

### JSON 로그를 콘솔에서 정리

```bash
kubectl -n sample-app logs deploy/sample-app --tail=100 | jq -r '"\(.time) \(.level) \(.msg) lat=\(.latency_ms)"'
kubectl -n sample-app logs -f deploy/sample-app | jq 'select(.level=="error")'
```

### 한계

- 로그 회전(노드 `containerLogMaxSize`, 기본 10Mi) 시 이전 내용 소실
- 파드가 삭제(스케일다운/재배포)되면 그 파드 로그는 `kubectl` 로 못 봄 → Loki 필요
- `-l` 은 과거 파드 안 잡음(현재 실행 중인 것만)

---

## 2. `stern` — 다중 파드 실시간 tail (권장)

설치: `brew install stern` / `scoop install stern` / [releases](https://github.com/stern/stern/releases) 바이너리.
필요 권한: 대상 네임스페이스 `pods`, `pods/log` `get/list/watch`.

```bash
stern sample-app -n sample-app                       # 이름에 'sample-app' 포함된 모든 파드
stern -n sample-app -l app=sample-app                # 라벨 셀렉터
stern -n sample-app 'sample-app-.*' --since 30m --tail 50
stern -n sample-app sample-app -c app                # 특정 컨테이너만
stern -n sample-app sample-app --exclude 'health check'   # 정규식 제외
stern --all-namespaces -l app.kubernetes.io/part-of=platform
stern -n sample-app sample-app -o raw | jq 'select(.level=="error")'   # JSON 파이프
stern -n sample-app sample-app --color always --template '{{.PodName}} {{.Message}}{{"\n"}}'
```

- 새로 뜨는 파드도 자동으로 붙음(재배포 중 로그 추적에 유리)
- `-o raw` : stern 프리픽스 없이 원본 라인만 → `jq`/`grep` 조합
- `--since`, `--tail` 로 항상 범위 제한(넓게 잡으면 API 부하)

대안: `kubetail`(bash), `kubectl-tail` 플러그인 — 기능은 stern 이 가장 풍부.

---

## 3. `logcli` — Loki 를 콘솔에서 조회

수집된 로그(과거 포함)를 LogQL 로. 설치: [Loki releases](https://github.com/grafana/loki/releases) 의 `logcli`.

### 접속 설정

```bash
export LOKI_ADDR="https://loki.example.com"          # 게이트웨이/인그레스 주소
# 인증 (환경에 맞게 택1)
export LOKI_USERNAME="..." LOKI_PASSWORD="..."       # basic auth
export LOKI_BEARER_TOKEN="..."                       # 또는 bearer
export LOKI_ORG_ID="tenant-a"                        # 멀티테넌트(X-Scope-OrgID)
```

인그레스가 없으면 포트포워딩 후 로컬 주소 사용:
```bash
kubectl -n logging port-forward svc/loki 3100:3100
export LOKI_ADDR="http://localhost:3100"
```

### 조회

```bash
# 최근 1시간, 네임스페이스 전체
logcli query '{namespace="sample-app"}' --since=1h --limit=200

# 기간 명시
logcli query '{namespace="sample-app"}' \
  --from="2026-09-08T00:00:00Z" --to="2026-09-08T01:00:00Z" --limit=1000

# JSON 파싱 + 필터
logcli query '{namespace="sample-app"} | json | level="error"' --since=6h

# 느린 요청만
logcli query '{namespace="sample-app"} | json | latency_ms > 500' --since=3h

# 실시간 스트리밍 (tail -f 상당)
logcli query '{namespace="sample-app"} | json | level="error"' --tail

# 출력 형식
logcli query '{namespace="sample-app"}' --since=1h -o raw       # 로그 라인만
logcli query '{namespace="sample-app"}' --since=1h -o jsonl     # 메타 포함 JSON
logcli query '{namespace="sample-app"}' --since=1h -o raw | jq .

# 메트릭 쿼리(에러율)
logcli query 'sum(rate({namespace="sample-app"} | json | level="error" [5m]))' --since=1h

# 라벨 탐색
logcli labels                                   # 라벨 키 목록
logcli labels namespace                          # 특정 키의 값
logcli series '{namespace="sample-app"}' --since=1h
```

### trace_id 로 파드 넘나들며 추적

```bash
logcli query '{namespace="sample-app"} | json | trace_id="abc123"' --since=24h -o raw
```

### 자주 쓰는 LogQL 조각

| 목적 | 예 |
|---|---|
| 특정 파드 | `{namespace="sample-app", pod="sample-app-xxx"}` |
| 문자열 포함 | `{namespace="sample-app"} |= "timeout"` |
| 정규식 제외 | `{namespace="sample-app"} != "GET /health"` |
| JSON 필드 추출 후 필터 | `... | json | status >= 500` |
| 라인 재포맷 | `... | json | line_format "{{.time}} {{.level}} {{.msg}}"` |
| 초당 로그량 | `sum(rate({namespace="sample-app"}[1m]))` |

---

## 4. `curl` + Loki HTTP API (logcli 없이)

```bash
LOKI="http://localhost:3100"     # 또는 인그레스 주소
ORG="-H X-Scope-OrgID:tenant-a"  # 멀티테넌트 아니면 생략

# 범위 쿼리 (start/end = Unix nanoseconds)
curl -s $ORG -G "$LOKI/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="sample-app"} | json | level="error"' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=200' | jq -r '.data.result[].values[][1]'

# 라벨/값
curl -s $ORG "$LOKI/loki/api/v1/labels" | jq
curl -s $ORG "$LOKI/loki/api/v1/label/namespace/values" | jq

# 실시간 tail (WebSocket) — websocat 필요
websocat "ws://localhost:3100/loki/api/v1/tail?query=%7Bnamespace%3D%22sample-app%22%7D"
```

Grafana 를 프록시로 쓰는 방법(별도 Loki 노출 없이, Grafana 인증 재사용):
```bash
curl -s -H "Authorization: Bearer $GRAFANA_TOKEN" -G \
  "https://grafana.example.com/api/datasources/proxy/uid/<loki-ds-uid>/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="sample-app"}' --data-urlencode 'start=...' --data-urlencode 'end=...'
```

---

## 5. Loki 가 외부에 노출 안 된 라이브 클러스터

우선순위:
1. **베스천/점프호스트에서** `kubectl -n logging port-forward svc/loki 3100:3100` → `logcli`/`curl`
2. 사내망 인그레스가 있으면 `LOKI_ADDR` 로 직접
3. Grafana 만 열려 있으면 4절의 **datasource proxy** 경로
4. 임시로 Loki 파드에 직접: `kubectl -n logging exec -it deploy/loki -- wget -qO- 'http://localhost:3100/loki/api/v1/labels'`

읽기 전용 접근 권장 RBAC: `logging` 네임스페이스 `pods`, `services`, `services/proxy`, `pods/portforward` 정도.

---

## 6. 매니지드 클라우드 로깅 (참고)

### EKS + CloudWatch (Container Insights / Fluent Bit)

```bash
# 로그 그룹 확인
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/<cluster>/

# 실시간 tail (CloudWatch Logs)
aws logs tail /aws/containerinsights/<cluster>/application --follow --since 15m \
  --filter-pattern '{ $.kubernetes.namespace_name = "sample-app" && $.log_processed.level = "error" }'

# 과거 조회
aws logs tail /aws/containerinsights/<cluster>/application --since 2h --format short

# Logs Insights (구조화 쿼리)
aws logs start-query --log-group-name /aws/containerinsights/<cluster>/application \
  --start-time $(date -d '1 hour ago' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, log_processed.msg | filter kubernetes.namespace_name="sample-app" and log_processed.level="error" | sort @timestamp desc | limit 100'
# → aws logs get-query-results --query-id <id>
```

### GKE + Cloud Logging

```bash
gcloud logging read \
  'resource.type="k8s_container" AND resource.labels.namespace_name="sample-app" AND jsonPayload.level="error"' \
  --limit=100 --freshness=1h --format='value(timestamp, jsonPayload.msg)'
```

### AKS + Azure Monitor

```bash
az monitor log-analytics query -w <workspace-id> --analytics-query \
  "ContainerLogV2 | where PodNamespace == 'sample-app' | where LogMessage has 'error' | take 100"
```

---

## 7. 실전 팁 / 주의

- **항상 범위를 좁혀라**: `--since` / `--tail` / `--limit` 없이 넓은 LogQL 은 Loki·API 서버에 부하. 운영에서 사고 유발.
- **`kubectl logs` 는 과거를 못 본다**: 재배포/스케일다운 후엔 Loki. 사후분석은 처음부터 Loki 로.
- **JSON 로그는 `jq` 와 조합**: `... -o raw | jq 'select(.status>=500)'`
- **요청 추적**: 앱이 `trace_id`(또는 `request_id`) 를 로그에 넣으면 파드·서비스 경계를 넘어 한 요청을 따라갈 수 있음.
- **멀티테넌트 Loki**: `X-Scope-OrgID` / `--org-id` 빠지면 "빈 결과" 로 보임(에러 아님).
- **시간대**: Loki/`logcli` 는 UTC 기준. `--timezone=Local` 로 바꿀 수 있음.
- **민감정보**: 콘솔 출력·복사 시 토큰/PII 노출 주의. 로그에 그런 게 보이면 마스킹 이슈로 보고.
- **권한 최소화**: 운영 조회용 계정은 `get/list/watch pods,pods/log` + Loki 읽기만.
- **큰 결과는 파일로**: `logcli query ... -o raw > /tmp/err.log` 후 로컬에서 분석.

---

## 8. 치트시트

```bash
# 지금 이 디플로이 에러만 실시간
stern -n sample-app -l app=sample-app -o raw | jq 'select(.level=="error")'

# 30분 전~지금, 500 응답
logcli query '{namespace="sample-app"} | json | status>=500' --since=30m -o raw | jq -r '"\(.time) \(.path) \(.status)"'

# 크래시 직전 로그 + 사유
kubectl -n sample-app logs <pod> -p; kubectl -n sample-app describe pod <pod> | sed -n '/Events/,$p'

# 특정 요청 추적
logcli query '{namespace="sample-app"} | json | trace_id="<id>"' --since=6h -o raw

# EKS CloudWatch 실시간
aws logs tail /aws/containerinsights/<cluster>/application --follow --since 10m
```
