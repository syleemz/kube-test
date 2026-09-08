# Grafana 로 로그 확인하기 (참조)

Grafana UI 에서 Loki 로그를 조회하는 방법. 로컬 테스트([PLAN.md](PLAN.md) 계열)와 라이브 클러스터 공통.
CLI 방식은 [LOGS-console.md](LOGS-console.md) 참고.

---

## 1. Grafana 접속

### 로컬 (계획서 3종)

| 노출 방식 | 접속 |
|---|---|
| port-forward | `kubectl -n monitoring port-forward svc/grafana 3000:80` → http://localhost:3000 |
| Ingress (kind/rancher) | http://grafana.localhost |
| LoadBalancer (rancher k3s) | `kubectl -n monitoring get svc grafana` 의 EXTERNAL-IP |

초기 계정: `admin` / (`grafana-values.yaml` 의 `adminPassword`, 기본 예시 `admin`).
Helm 이 랜덤 생성했다면:
```bash
kubectl -n monitoring get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

### 라이브 클러스터

- 보통 사내 SSO(OAuth/SAML/LDAP)로 로그인. 조직에서 부여한 **Role** 이 기능을 좌우:
  - **Viewer**: 대시보드만. Explore 는 조직 설정에 따라 비활성일 수 있음.
  - **Editor 이상**: Explore, 쿼리 자유 사용.
- Explore 가 안 보이면 관리자에게 `Editor` 또는 "Viewers can access Explore" 설정 요청.

---

## 2. Loki 데이터소스 확인

**Connections → Data sources → Loki** (계획서에선 Helm values 로 자동 프로비저닝됨).

- **URL**: `http://loki.logging.svc.cluster.local:3100` (클러스터 내부) 또는 게이트웨이 주소
- **HTTP Headers**: 멀티테넌트면 `X-Scope-OrgID: <tenant>` 추가 (없으면 결과가 빈 것처럼 보임)
- **Maximum lines**: 기본 1000. 넓게 보려면 늘리되 성능 주의
- 하단 **Save & test** → "Data source successfully connected" 확인
- 여러 Loki(스테이징/운영)면 데이터소스가 여러 개 → Explore 에서 선택

---

## 3. Explore 로 로그 보기 (핵심)

좌측 나침반 아이콘 **Explore** → 상단에서 데이터소스 **Loki** 선택.

### 3-1. 쿼리 입력

- **Label filters** (Builder 모드): `namespace` `=` `sample-app` 선택 → 자동으로 `{namespace="sample-app"}`
- **Label browser**: 라벨 키/값을 클릭으로 탐색 후 "Show logs"
- **Code 모드** 토글: LogQL 직접 입력 (4절 예시)
- 우상단 **시간 범위**: `Last 15 minutes` 등. 조회는 이 범위 안에서만.
- **Run query** (Shift+Enter). 우상단 새로고침 옆 ▾ 에서 자동 새로고침(5s~) 설정.

### 3-2. 로그 패널 읽기

- 상단 **볼륨 히스토그램**: 시간대별 로그량. 막대 드래그 → 그 구간으로 줌인.
- 로그 라인 좌측 색 띠 = **레벨**(`| json`/`| logfmt` 로 `level` 인식 시 색상). 
- 툴바:
  - **Time** / 순서 **Newest first ↔ Oldest first**
  - **Wrap lines** 줄바꿈
  - **Prettify JSON** JSON 로그 들여쓰기
  - **Deduplication** (exact/numbers/signature) 반복 라인 접기
- 라인 클릭 → 펼침:
  - **Fields / Detected fields**: `| json` 이면 파싱된 필드 표시
  - 각 필드 옆 돋보기 `+` / `−` → `field="값"` / `field!="값"` 를 쿼리에 자동 추가
  - **Show context**: 같은 스트림의 해당 라인 앞뒤 로그
  - 라벨 클릭 → 필터 추가

### 3-3. 실시간 보기 (Live)

- 로그 패널 우상단 **Live** 버튼 → WebSocket tail, 새 로그가 아래로 흐름
- **Pause** 로 멈춤. 범위 넓은 쿼리로 Live 켜면 부하 → 라벨 좁힌 뒤 사용
- (`| json | level="error"` 같이 걸어두고 Live → 에러만 실시간)

### 3-4. Split view

우상단 **Split** → 좌우 두 패널.
- 왼쪽: 로그(`{namespace="sample-app"}`)
- 오른쪽: 메트릭(`sum(rate({namespace="sample-app"} | json | level="error"[1m]))`)
- 시간 범위 동기화되어 스파이크 ↔ 로그 대조 가능

### 3-5. 결과 내보내기 / 공유

- 로그 패널 메뉴 → **Download**: `txt` / `json` 로 저장
- Explore 우상단 **Share** → short link (시간 범위·쿼리 포함 URL)
- **Add to dashboard**: 현재 쿼리를 패널로 저장

---

## 4. Explore 에서 자주 쓰는 LogQL

| 목적 | 쿼리 |
|---|---|
| 네임스페이스 전체 | `{namespace="sample-app"}` |
| 특정 파드/컨테이너 | `{namespace="sample-app", pod=~"sample-app-.*", container="app"}` |
| 문자열 포함 / 제외 | `{namespace="sample-app"} |= "timeout" != "GET /health"` |
| JSON 파싱 후 레벨 필터 | `{namespace="sample-app"} | json | level="error"` |
| 상태코드 / 지연 | `{namespace="sample-app"} | json | status>=500` · `... | latency_ms > 500` |
| logfmt 로그 | `{namespace="sample-app"} | logfmt | duration > 1s` |
| 라인 재구성 | `{namespace="sample-app"} | json | line_format "{{.time}} {{.level}} {{.msg}}"` |
| 요청 추적 | `{namespace="sample-app"} | json | trace_id="abc123"` |
| 초당 로그량(그래프) | `sum(rate({namespace="sample-app"}[1m]))` |
| 에러율 | `sum(rate({namespace="sample-app"} | json | level="error"[5m]))` |
| 경로별 5xx 카운트 | `sum by (path) (count_over_time({namespace="sample-app"} | json | status>=500 [5m]))` |

> 메트릭 쿼리(`rate`, `count_over_time` 등)를 입력하면 Explore 가 자동으로 **그래프**로 표시한다.

---

## 5. 대시보드로 상시 모니터링

### 로그 패널 추가

- 새 Dashboard → Add visualization → 데이터소스 Loki → Visualization **Logs**
- 쿼리: `{namespace="$namespace"} | json` (아래 변수 사용)
- 옵션: Wrap lines, Prettify JSON, Enable log details, Order

### 대시보드 변수 (Dashboard settings → Variables)

| 변수 | Type | Query |
|---|---|---|
| `namespace` | Query | `label_values(namespace)` |
| `pod` | Query | `label_values({namespace="$namespace"}, pod)` |
| `level` | Custom | `debug,info,warn,error` |

패널 쿼리에서 `{namespace="$namespace", pod=~"$pod"} | json | level=~"$level"` 형태로 사용.

### 메트릭 패널 (Timeseries / Stat)

- 에러율: `sum(rate({namespace="$namespace"} | json | level="error"[5m]))`
- 총 로그량: `sum(rate({namespace="$namespace"}[1m]))`
- Stat 패널로 "최근 5분 에러 수": `sum(count_over_time({namespace="$namespace"} | json | level="error"[5m]))`

### Derived fields (trace 연동, 선택)

Loki 데이터소스 설정 → **Derived fields**:
- Name `trace_id`, Regex `"trace_id":"(\w+)"`, URL `${__value.raw}`, Internal link → Tempo
- 로그 상세에서 `trace_id` 옆 버튼으로 트레이스로 점프

---

## 6. 알림 (선택)

**Alerting → Alert rules → New**:
- Data source: Loki
- Query: `sum(rate({namespace="sample-app"} | json | level="error"[5m]))`
- Condition: `IS ABOVE 0.1` for `5m`
- Contact point: Slack/Email 등

> Loki 자체 ruler 를 쓰는 방법도 있으나(운영 표준), 로컬 학습은 Grafana Alerting 이 간단.

---

## 7. 트러블슈팅

| 증상 | 확인 |
|---|---|
| "No logs volume available" / 결과 없음 | 시간 범위(너무 좁음/과거), 라벨 오타, 데이터소스 URL |
| 계속 빈 결과인데 에러는 없음 | 멀티테넌트 Loki 인데 `X-Scope-OrgID` 헤더 누락 |
| 레벨 색상/필드가 안 나옴 | `| json` 또는 `| logfmt` 를 쿼리에 안 넣음 |
| `| json` 후 필드 필터가 에러 | 필드명 대소문자, 중첩 필드는 `| json foo="bar.baz"` 로 별칭 |
| 로그가 잘림/1000줄에서 멈춤 | 데이터소스 **Maximum lines** ↑, 또는 시간 범위 축소 |
| Explore 메뉴가 없음 | Role 이 Viewer → Editor 요청, 또는 대시보드 패널로만 조회 |
| 쿼리가 매우 느림 / 타임아웃 | 라벨로 먼저 좁히고(`namespace`,`pod`) 그다음 `|=`/`| json`, 시간 범위 축소 |
| Live 가 안 뜸 | WebSocket 차단(프록시/인그레스 설정), 범위 넓은 쿼리 |
| 시간이 안 맞음 | Grafana 우상단 → Change time settings → Timezone, Loki 는 기본 UTC |

---

## 8. 빠른 순서 (요약)

1. `kubectl -n monitoring port-forward svc/grafana 3000:80` → http://localhost:3000 (admin / 비번)
2. Explore → 데이터소스 **Loki**
3. Label filter: `namespace = sample-app` → Run
4. 에러만: 코드 모드로 `{namespace="sample-app"} | json | level="error"`
5. 라인 펼쳐 필드 확인 → `+`/`−` 로 조건 추가, **Show context** 로 전후 확인
6. 실시간은 **Live**, 스파이크 대조는 **Split** + 메트릭 쿼리
7. 계속 볼 쿼리는 **Add to dashboard**, 결과는 **Download**
