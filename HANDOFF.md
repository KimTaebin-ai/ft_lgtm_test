# HANDOFF

피처 블록은 이 줄 아래에 최신이 위로 오도록 추가한다.

<!-- 피처 블록 템플릿
## F-Mx-xx <이름> (브랜치 feat/mx-xx-<이름>)
### 한 일
### 된 것
### 안 된 것
### 다음 단계
-->

## F-M1-04 metrics-exemplar (브랜치 feat/m1-04-metrics-exemplar)

### 한 일
- `telemetry.Setup`: `otlpmetricgrpc`(v1.47.0) + `PeriodicReader(WithInterval(5s))` → Collector. 같은 resource(`service.name=lgtm-backend`). Shutdown 순서 metric → log → trace
- `telemetry/metrics.go`: instrument 3개. bucket `0.05 … 20` 공통 (`DurationBuckets`)
- `execute/handler.go`: stage duration은 `step()`에서 stage span ctx로 `span.End()` 전에 기록, execution counter/duration은 응답 쓰기 직전 root span이 살아 있는 `r.Context()`로 기록 (otelhttp가 ServeHTTP 반환 뒤 End). duration 값은 ServeHTTP 진입 시각부터의 시간이라 root span 시작과 ms 미만 차이가 있음. 400 invalid_request는 metric 미기록
- `scripts/load.sh`: 단발 모드(`-n`, `--ok/--slow/--fail`)와 지속 모드(`-d <초> [--interval <초>]`, 정상 70/slow 15/fail 15 가중 랜덤). stdout `<kind> <status> <trace_id>`, stderr 요약. M5 dashboard 개발·디펜스 시연용. verify는 단발 모드만 사용
- `make verify-m1`: m1-01 → m1-04 순차, 첫 실패에서 중단
- `scripts/verify/m1-04.sh` (실패 상태로 먼저 커밋: VM에서 15건 실패 확인)

### 확정 결정과 이유
- **OTel 이름에 접미사를 쓰지 않는다**: `lgtm_executions`(→ `_total`), `lgtm_execution_duration` / `lgtm_stage_duration`(unit `s` → `_seconds`). 실측 Mimir 이름이 PRD와 정확히 일치함
- exemplar: otel-go sdk/metric v1.47.0은 **기본 활성**, 기본 filter `TraceBasedFilter` (`config.go newConfig`). `OTEL_GO_X_EXEMPLAR` 불필요. 바꾸려면 `WithExemplarFilter` 또는 `OTEL_METRICS_EXEMPLAR_FILTER`
- Collector `prometheus_remote_write`는 exemplar 설정 키 없이 전송함 (`pkg/translator/prometheusremotewrite/helper.go` `getPromExemplars`, v0.163.0). **collector.yaml 변경 없음**, Mimir `max_global_exemplars_per_user`는 F-M1-01에서 이미 설정
- Mimir exemplar label 키 실측: `trace_id`, `span_id` → Grafana `exemplarTraceIdDestinations.name: trace_id` 그대로 일치
- 근거 URL: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.163.0/pkg/translator/prometheusremotewrite/helper.go , https://github.com/open-telemetry/opentelemetry-specification/blob/v1.40.0/specification/compatibility/prometheus_and_openmetrics.md , https://github.com/open-telemetry/opentelemetry-specification/blob/d4b241f451674e8f611bb589477680341006ad2b/specification/configuration/sdk-environment-variables.md#exemplar

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 exit 0 | VM 실행 (`make1=0 make2=0`) | 확인(VM) |
| `make verify-m1` exit 0 (m1-01~m1-04 전부 ALL PASS) | VM 실행. m1-02 수정(아래) 후 재실행한 결과 | 확인(VM) |
| Mimir 저장 이름이 PRD와 정확히 일치: `lgtm_executions_total`, `lgtm_execution_duration_seconds_{bucket,sum,count}`, `lgtm_stage_duration_seconds_{bucket,sum,count}` | `m1-04.sh` (label/__name__/values 출력) | 확인(VM) |
| `status="success"` > 0, `status="compile_error"` > 0 | `m1-04.sh` | 확인(VM) |
| 두 histogram의 `le` 집합 == PRD bucket + `+Inf` | `m1-04.sh` | 확인(VM) |
| label 세트: executions/duration `language,status`, stage `stage`; cid/hash/sha 류 없음 | `m1-04.sh` | 확인(VM) |
| `query_exemplars`가 `trace_id`(+`span_id`) 라벨 반환, load.sh 응답 trace_id와 일치, Tempo 조회됨 | `m1-04.sh` | 확인(VM) |
| Grafana `exemplarTraceIdDestinations.name: trace_id` == 실측 키 | `m1-04.sh` (grafana.yaml 파싱 vs 실측) | 확인(VM). 설정 존재·일치만, UI 동작은 미확인 |
| load.sh 지속 모드 (`-d 6 --interval 1`) 가 요청을 계속 보내고 종료 0 | VM 실행 (total=4, errors=0) | 확인(VM). 짧은 구간만 |
| 계측 이름/unit/bucket/label/exemplar trace_id(root·stage ctx), 400은 미기록 | `go test` (ManualReader) | 확인(mac 정적). VM에서 go test는 실행 안 함 |
| Grafana Explore에서 exemplar 점 클릭 → Tempo → Related logs | — | **미확인** (위 수동 절차) |
| amd64, Mimir/Collector 장애 중 metric 유실 허용 범위 | — | 미확인 |

### 범위 밖 수정 (이유)
- `scripts/verify/m1-02.sh` 1줄: Collector 로그 error 검사에서 `Exporting failed` 줄을 제외. 원인: m1-01이 mimir/loki/tempo를 일부러 삭제하는데, F-M1-04부터 backend가 5초마다 metric을 보내서 재시작 구간의 PRW 전송 실패(`context deadline exceeded`, dropped_items 10 × 3건)가 error로 찍혀 `make verify-m1`의 m1-02가 실패했다. 기동/설정 오류 검사는 그대로 유지. 첫 실행(수정 전)은 이 때문에 `verify-m1=2`였다.
- 유의: `make clean && make`(make1/make2=0)는 이 수정 전에 실행했고, verify-m1 통과는 수정 후 같은 클러스터에서 재실행한 결과다. 수정 후 `make clean`부터 다시 돌린 것은 아님.


### 안 된 것
- Grafana UI에서 exemplar 점 클릭 → Tempo → Related logs 클릭 이동은 **미확인** (아래 수동 절차)
- `lgtm_queue_rejected_total`(F-M2-04), `lgtm_output_bytes`(M5)는 범위 밖
- 실제 compile/execute 값이 아니라 stub sleep 기반 duration

### 수동 확인 절차 (VM 브라우저, 1회)
1. VM에서 트래픽: `bash scripts/load.sh -d 120 --interval 1`
2. Firefox `http://grafana.lgtm.local` → Explore → datasource **Mimir** → 쿼리 `histogram_quantile(0.95, sum by (le) (rate(lgtm_execution_duration_seconds_bucket[1m])))`
3. 쿼리 옵션에서 **Exemplars** 켜기 → Run → 그래프의 점(exemplar)에 마우스를 올려 `trace_id` 확인
4. 점의 **Query with Tempo**(trace_id 링크) 클릭 → Tempo trace 열림
5. span(예: `compile`) 클릭 → **Logs for this span** 클릭 → Loki 로그 1줄 이상 확인
(점이 안 보이면 시간 범위를 Last 5 minutes로 좁히고 load.sh가 도는 동안 확인. 스크린샷 1장 남기기)

### 다음 단계
- F-M2-01 compiler-service (rustc → wasm32-wasip1, 별도 pod, traceparent 전파로 backend → rustc span이 한 trace)
- M5 dashboard에서 `load.sh -d`를 트래픽 소스로 사용

## F-M1-03 backend-skeleton (브랜치 feat/m1-03-backend-skeleton)

### 한 일
- `backend/` Go 모듈 `lgtm/backend` (Go **1.27.3**). `cmd/api`(서버, SIGTERM → `http.Server.Shutdown` → provider Shutdown으로 flush), `internal/telemetry`(Tracer/Logger provider, slog fan-out), `internal/execute`(stub). F-M2-01 compiler는 `backend/cmd/compiler`로 같은 모듈에 추가
- `GET /healthz`(계측·로그 없음, Ingress 미노출), `POST /api/execute` stub: compile 20~40ms / execute 10~30ms / ipfs.upload 50~100ms sleep, cid는 `bafy`+코드 sha256 앞 52자의 **가짜 값**. 트리거: `__fail_compile__`(status compile_error), `__slow__`(합계 2~3초). 400 invalid_request(JSON 오류, language≠rust, 빈 code)만 처리. **64KB 413 / 429는 F-M2-04 전까지 없음 → 본문 크기 무제한**
- Tracing: root span 이름은 `execute.RootSpanName`(`"POST /api/execute"`)을 `otelhttp.WithSpanNameFormatter`로 고정. 자식 `compile`(Client) / `execute` / `ipfs.upload`. attribute `code.sha256`, `code.language`, `code.size_bytes`(root), `ipfs.cid`(ipfs.upload + root). 실패 시 해당 span과 root에 `RecordError`(exception event) + `SetStatus(Error)`. W3C TraceContext propagator 등록. OTLP gRPC `otel-collector.observability:4317`(env `OTLP_ENDPOINT`로 변경 가능), `service.name=lgtm-backend`
- Logs: `slog.NewMultiHandler(otelslog, JSON stdout)`. JSON 쪽은 `ctxHandler`가 `trace_id`/`span_id`를 최상위에 넣고, `WithAttrs`/`WithGroup`도 래퍼를 유지(그룹이 열려 있으면 root에 trace attr을 먼저 붙여 재구성). 모든 로그는 `*Context(ctx, …)`. 각 단계 span 안에서 최소 1줄
- 이미지/배포: `backend/Dockerfile`(multi-stage, `RUN --mount=type=cache`로 go mod/build 캐시, non-root 65532). `k8s/app/`(ns `lgtm`, Deployment+Service+Ingress `lgtm.local` `/api` Prefix). `make build` = `scripts/build.sh`(없으면 docker build → `k3d image import`), `make deploy`가 `__BACKEND_IMAGE__` 치환 후 apply + rollout + `scripts/wait-backend.sh`
- `scripts/verify/m1-03.sh` (실패 상태로 먼저 커밋: VM에서 39건 실패)

### 확정 결정과 이유
- **이미지 태그 = 소스 content hash** `lgtm-backend:src-<12자>` (`scripts/image-tag.sh`: `backend/` 전 파일 경로+내용 sha256). VM에 .git이 없고, 시간 태그는 make 재실행마다 이미지가 바뀌어 idempotent 위반. 같은 소스는 같은 태그(build skip, deploy 변화 없음), 소스가 바뀌면 태그가 바뀌어 Deployment가 롤링 교체됨. `:latest` 없음, `imagePullPolicy: IfNotPresent`. 이전 태그는 docker host에서만 정리, **k3d 노드 containerd에는 남음**
- **base 이미지**: 빌드 `golang:1.27.3-trixie`, 런타임 `debian:trixie-20261020-slim`(날짜 태그 고정). F-M2-03에서 wasmtime-go(cgo, glibc 링크)로 바뀔 때 base 교체가 없도록 alpine(musl)/distroless-static을 피하고 VM과 같은 Debian 13 glibc로 맞춤. 지금은 `CGO_ENABLED=0` 정적 빌드
- 6.2 해석: 성공/실패 모두 같은 응답 구조체(모든 필드 항상 포함, `message`만 omitempty). `__fail_compile__`은 compile 실패 → execute 생략 → ipfs.upload 수행 → trace는 span **3개**(성공은 4개)
- 버전 (go.mod에서 확인): otel / sdk / trace / otlptracegrpc **v1.47.0**, otel/log·sdk/log **v1.47.0**, otlploggrpc **v0.23.0**, contrib otelslog **v0.21.0**, otelhttp **v0.72.0**, grpc v1.83.2. 근거 URL: https://go.dev/dl/?mode=json, https://pkg.go.dev/log/slog (`NewMultiHandler`, Go 1.26.0 추가), pkg.go.dev 각 모듈 versions 탭, Docker Hub debian `trixie-20261020-slim`

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 exit 0 | VM 실행 (`make1=0 make2=0`) | 확인(VM) |
| backend pod Ready, request/limit, 이미지 태그 고정, IfNotPresent | `m1-03.sh` | 확인(VM) |
| `POST /api/execute` 200 + 6.2 필드 전부 | `m1-03.sh` | 확인(VM) |
| Tempo: span 4개, root 이름 `POST /api/execute`, 자식 parent=root, TR-03 attribute | `m1-03.sh` | 확인(VM) |
| Loki `{service_name="lgtm-backend"} \| trace_id=` ≥1, 3개 자식 span 각각 `\| span_id=` ≥1 | `m1-03.sh` | 확인(VM) |
| kubectl logs JSON에 같은 trace_id + span_id | `m1-03.sh` | 확인(VM) |
| `__fail_compile__`: compile_error, compile·root ERROR, event 존재, span 3개 | `m1-03.sh` | 확인(VM) |
| `__slow__` 2~3.5초 | `m1-03.sh` | 확인(VM) |
| `lgtm.local /` 와 `/healthz` 본문이 dummy 텍스트 (healthz가 backend로 안 감) | `m1-03.sh` | 확인(VM) |
| m1-01, m1-02 여전히 통과 | `m1-03.sh` 내부 호출 | 확인(VM) |
| 코드 수정 → `make build && make deploy` → 새 태그(`9d3f…`→`55ff…`)로 교체, 응답에 변경 반영, 무변경 재실행은 build skip | VM 실행 | 확인(VM) |
| ctxHandler가 `With`/`WithGroup` 조합에서도 trace_id를 최상위에 유지, MultiHandler fan-out | `go test` 단위 테스트 | 확인(mac 정적). VM 실행 안 함 |
| stub 스키마/span 구성/트리거/400 | `go test` | 확인(mac 정적) |
| Grafana Explore에서 trace → "Logs for this span" 클릭 이동 | — | **미확인** (아래 수동 절차) |
| OTLP exporter 실패(Collector 다운) 시 동작 | — | 미확인 |
| amd64 | — | 미확인 (VM은 aarch64) |

실측: `kubectl top pod -n lgtm` backend 1m / 19Mi (limit 200m/128Mi), 유휴.

### 수동 확인 절차 (VM 브라우저, 1회)
1. Firefox로 `http://grafana.lgtm.local` → Explore → datasource **Tempo** → Query type **TraceQL**(또는 TraceID) → trace ID 입력:
   - 성공 trace: `256307ecde8dcf0cbb06e80f26395ea8`
   - compile_error trace: `22c80413bfa70173357abb2044990bce`
   (없으면 `curl -s -X POST --resolve lgtm.local:80:127.0.0.1 -d '{"language":"rust","code":"fn main(){}"}' http://lgtm.local/api/execute` 로 새로 만들고 응답의 `trace_id` 사용)
2. span 목록에서 `compile` 등 자식 span 클릭 → 상세 패널의 **Logs for this span** 버튼 클릭 → Loki 쿼리 `{service_name=~".+"} | trace_id="…" | span_id="…"` 로 이동하고 로그가 1줄 이상 나오는지 확인
3. compile_error trace에서는 compile / root span이 ERROR로 표시되고 exception event가 보이는지 확인
(m1-02에서 provisioned 쿼리를 Loki API로 직접 실행하는 검증은 통과. 버튼 클릭 자체만 미확인.)

### 안 된 것
- metrics/exemplar (F-M1-04), 실제 compile/실행/IPFS, 413/429 (F-M2-04), compiler pod, frontend
- k3d 노드 containerd의 오래된 `lgtm-backend:src-*` 이미지 정리

### 다음 단계
- **F-M1-04 metrics-exemplar**: `lgtm_execution_duration` histogram + exemplar(trace_id), counter. stub 트리거(`__slow__`, `__fail_compile__`)로 느린/실패 trace 생성. Mimir에 저장된 실제 metric 이름은 조회로 확정. m1-02 HANDOFF의 `service.name → job` label 변환 확인 결과 참고

## F-M1-02 collector-grafana (브랜치 feat/m1-02-collector-grafana)

### 한 일
- `k8s/observability/collector.yaml`: OTel Collector contrib `0.163.1` (Deployment 1, ClusterIP Service 4317/4318, Ingress 없음). receivers otlp(grpc/http), processors memory_limiter+batch, pipelines traces/metrics/logs, `health_check`(13133) → readiness/liveness. limit 500m/256Mi
- exporter 이름은 `otelcol-contrib components`(VM, 0.163.1) 출력으로 확인: `otlp_grpc`(Tempo, `tempo.observability:4317`), `prometheus_remote_write`(Mimir `/api/v1/push`), `otlp_http`(Loki `/otlp`, `/v1/logs` 자동 부착). 구 이름 `otlp`/`otlphttp`/`prometheusremotewrite`는 deprecated alias라 쓰지 않음
- `k8s/observability/grafana.yaml`: Grafana `13.2.4` (Deployment, PVC 없음, limit 500m/512Mi) + Ingress `grafana.lgtm.local` + provisioning ConfigMap 2개(datasources, dashboard provider). `k8s/dummy/grafana.yaml` 삭제
- `make deploy`: Secret `grafana-admin`(없을 때만 랜덤 생성, 출력 안 함) → `dashboards/*.json`으로 ConfigMap `grafana-dashboards`(0개면 빈 것) → apply → rollout 대기 → 기존 클러스터의 `dummy-grafana` 삭제(`apply`는 prune 안 함; 실제로 구 dummy를 apply한 뒤 `make deploy`로 제거됨 확인)
- `scripts/wait-ingress.sh`: `host[/path]` 인자 지원. grafana는 `/api/health` 200 기대
- `scripts/verify/m1-02.sh` (실패 상태로 먼저 커밋: VM에서 28건 실패 확인)
- `scripts/verify/m1-01.sh` 최소 수정: 같은 namespace에 Collector/Grafana가 생겨 "pod 3개", "Ingress 0개" 검사가 깨지므로 `app in (mimir,loki,tempo)` 라벨로 한정, Ingress는 backend 3종을 가리키는 것만 센다 (PRD 변경 아님, 검증 범위 조정)

### 확정 결정과 이유
- Grafana 접근: anonymous **Editor**. Viewer는 Explore 접근이 막혀 trace-to-logs가 깨질 수 있어서. 로그인 폼 숨김. admin은 랜덤 Secret (기본 admin/admin 금지). PRD 14장 해소. admin/admin 으로는 admin API 불가 (verify 확인; 익명 사용자의 정확한 응답 코드는 미확인)
- 외부 통신 차단 (env `GF_<SECTION>_<KEY>`, 13.2.4 `defaults.ini`로 키 존재 확인, 적용값은 `/api/admin/settings`로 verify): analytics.reporting_enabled / check_for_updates / check_for_plugin_updates / feedback_links_enabled=false, news.news_feed_enabled=false, snapshots.external_enabled=false, plugins.preinstall_disabled=true, preinstall_auto_update=false, plugin_admin_enabled=false. (`preinstall_async` 키는 13.2.4에 없음)
- tracesToLogsV2.query: `{service_name=~".+"} | trace_id="$${__trace.traceId}" | span_id="$${__span.spanId}"`. LogQL은 `{...}`로 시작해야 하므로 stream selector 포함. `$$`는 provisioning의 `$` 이스케이프
- tracesToMetrics.tags: `service.name → job`. remote write 변환 후 `service.name`이 `job` label이 됨을 실측으로 확인(아래). queries는 비워둠 (spanmetrics는 F-M5-03)
- Loki derivedFields: `matcherType: label`, `matcherRegex: trace_id` (structured metadata 기준, 로그 본문 regex 아님). provisioning 후 API 응답에 `matcherType: label`이 남는 것 확인
- 근거 URL: https://grafana.com/docs/grafana/v13.2/datasources/tempo/configure-tempo-data-source/ (변수 `${__trace.traceId}`, `${__span.spanId}`), …/configure-tempo-data-source/provision/ (tracesToLogsV2/tracesToMetrics YAML, `$$` 이스케이프), …/datasources/prometheus/configure/ (exemplarTraceIdDestinations), …/datasources/loki/configure/ (derivedFields), …/administration/provisioning/ (dashboard provider). Collector: opentelemetry-collector-contrib v0.163.0 exporter README

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 exit 0 | VM에서 실행, 재실행 `MAKE_RERUN_EXIT=0` | 확인(VM) |
| collector/grafana Ready + request/limit | `scripts/verify/m1-02.sh` | 확인(VM) |
| Collector `otelcol-contrib validate` 성공, 기동 로그 error 0 | m1-02 | 확인(VM) |
| `/api/health` 200 (Ingress), 인증 없이 홈 200 / `/api/search` 200 | m1-02 | 확인(VM) |
| admin/admin 불가, Secret 비밀번호로 admin API 200 | m1-02 | 확인(VM) |
| 설정 적용값 (anonymous Editor, 외부 통신 차단 키) | `/api/admin/settings` | 확인(VM) |
| datasource 3개(uid mimir/tempo/loki) 존재 + health OK | Grafana API | 확인(VM) |
| exemplarTraceIdDestinations, tracesToLogsV2(customQuery, span_id), derivedFields(label) | datasource API JSON | 확인(VM) |
| provisioned tracesToLogsV2.query를 trace/span id로 치환해 Loki query_range 실행 → 1건 | m1-02 | 확인(VM) |
| Collector→Tempo / Loki(`\| trace_id=`) / Mimir smoke | m1-02 | 확인(VM) |
| Mimir 저장 label 세트 (service.name=verify-m1-02 로 전송) | `/prometheus/api/v1/series` | 확인(VM): `{__name__="verify_m1_02_gauge", job="verify-m1-02", otel_scope_name="verify"}` |
| Grafana 로그에 외부 다운로드/플러그인 설치 시도 없음 | 로그 grep | 확인(VM) |
| Grafana pod 삭제 후 datasource 3개 유지, PVC 없음 | m1-02 | 확인(VM) |
| m1-01 여전히 통과 | `scripts/verify/m1-01.sh` | 확인(VM) |
| 구 `dummy-grafana`가 있는 클러스터에서 `make deploy`가 제거 | 구 manifest apply 후 deploy | 확인(VM) |
| YAML/스크립트 문법 | `bash -n` (mac) | 확인(mac 정적) |
| metric → trace → logs 클릭 이동, exemplar end-to-end | — | **미확인** (앱 없음, F-M1-04 범위) |
| tracesToMetrics 링크 실제 렌더링 (queries 없음) | — | **미확인** (F-M5-03 spanmetrics 이후) |
| amd64 | — | 미확인 (VM은 aarch64) |

### 실측 (`kubectl top pod -n observability`, VM, 유휴, 재배포 직후 약 1~3분)
| pod | CPU | MEM |
|---|---|---|
| grafana | 8m | 294Mi (limit 512Mi) |
| otel-collector | 8m | 43Mi (limit 256Mi) |
| loki-0 / mimir-0 / tempo-0 | 5m / 5m / 2m | 43Mi / 59Mi / 44Mi |
| node k3d-lgtm-server-0 | 111m (2%) | 1835Mi (23%) |

### 안 된 것
- 클릭 이동(metric→trace→logs) 확인, Collector→Mimir exemplar 전달 실측: F-M1-04
- tracesToMetrics `queries`, serviceMap, nodeGraph: 범위 밖
- dashboard JSON: M5. provider만 설정됨 (`dashboards/` → ConfigMap → `/var/lib/grafana/dashboards`). 새 JSON 추가 후에는 `make deploy`를 다시 실행해야 ConfigMap이 갱신됨

### 다음 단계
- F-M1-03 backend-skeleton
- Collector는 delta metric을 버리므로(prometheus_remote_write 문서) 앱 metric은 cumulative로 export할 것

## F-M1-01 obs-backends (브랜치 feat/m1-01-obs-backends)

### 한 일
- `k8s/observability/`: namespace + Mimir/Loki/Tempo 각각 ConfigMap + StatefulSet(1) + ClusterIP Service + PVC(local-path). Ingress 없음. 모든 컨테이너 request/limit, `readinessProbe httpGet /ready`
- 이미지(확인일 2026-10-21, amd64/arm64 모두 Docker Hub 태그 API로 확인): `grafana/mimir:3.2.2`, `grafana/tempo:3.1.0`, `grafana/loki:3.7.9`. 버전은 각 GitHub `releases/latest`로 확인
- `make deploy`: `k8s/observability/` apply → `rollout status statefulset/{mimir,loki,tempo}`(readinessProbe 기반, port-forward 안 씀) → `k8s/dummy/` apply → 기존 dummy 대기
- `scripts/verify/m1-01.sh` (실패 상태로 먼저 커밋, 구현 전 VM에서 5건 실패 확인). port-forward는 verify 안에서만 사용, trap으로 정리

### 확정 결정과 이유
- 배포: 셋 다 raw manifest. Mimir 공식 chart가 distributed 위주라 monolithic에 맞지 않고, 세 백엔드의 방식을 통일하기 위해
- Collector→Mimir: `prometheusremotewrite` (`/api/v1/push`). Collector→Loki: `otlphttp` (`/otlp`). Collector 자체는 F-M1-02. (OTLP→Mimir 경로의 exemplar 전달은 확인하지 않았고 F-M1-04에서 실측)
- Mimir classic: 3.x에서 `ingest_storage.enabled` 기본값은 false이고 켜려면 명시해야 한다(https://grafana.com/docs/mimir/v3.2.x/configure/configuration-parameters/). 문서는 ingest storage를 "preferred"라 하지만 monolithic 설명(https://grafana.com/docs/mimir/v3.2.x/references/architecture/deployment-modes/)에는 언급이 없다. 그래서 `ingest_storage.enabled: false`를 명시했고 `/config`로 반영을 확인
- `max_global_exemplars_per_user` 기본값 0(비활성, experimental)이라 100000으로 설정. `/config`에서 반영 확인
- Tempo 3.x: ingester/compactor 블록 제거, monolithic은 Kafka 불필요(https://grafana.com/docs/tempo/v3.1.x/set-up-for-tracing/setup-tempo/migrate-to-3/). metrics-generator/local_blocks는 설정하지 않음(F-M5-03에서 이 문서 기준으로 다시 확인)
- Loki: schema v13 + tsdb, `allow_structured_metadata: true`, OTLP는 `/otlp/v1/logs`. 성공 응답은 200이 아니라 **204**

### Mimir ruler/alertmanager 스토리지 문제 (기록)
- 증상: Mimir CrashLoop, `module=ruler err="unable to read dir /data/ruler: open /data/ruler: no such file or directory"`. 이전에 `activity-tracker`도 `./metrics-activity.log` permission denied로 실패 → `activity_tracker.filepath: /data/metrics-activity.log`
- 확인: `docker run --rm --entrypoint /bin/mimir grafana/mimir:3.2.2 -modules` 에서 `ruler (in: all)`, `alertmanager`는 all에 포함되지 않음. 그래서 alertmanager 설정은 넣지 않았다
- 선택: `ruler_storage.backend: filesystem`, `dir: /data/ruler`(PVC 안). 이유: backend `local`은 디렉터리가 없으면 시작이 실패하고, `filesystem`(object store 방식)은 디렉터리 없이도 시작되는 것을 VM에서 확인(수정 후 `logs | grep level=error` 0건). rule/alert 기능은 쓰지 않는다
- 대안(끄는 방법): `-target=all` 대신 모듈을 나열하면 ruler를 뺄 수 있다. `-modules` 출력 기준이며 모듈 제외 문법(`-ruler`)은 문서에서 확인하지 못했다. emptyDir를 `/data/ruler`에 마운트하는 방법도 있으나 시도하지 않았다
- ring: `/config` 확인 결과 기본값 memberlist였던 것 중 `-target=all`에서 실제로 쓰는 ruler/query_scheduler/querier ring을 포함해 distributor/ingester/store_gateway/compactor ring을 inmemory로 설정. 남은 memberlist는 `distributor.ha_tracker`(비활성), `ingester.partition_ring`(ingest storage용), alertmanager, usage_tracker, overrides_exporter로 이 구성에서 쓰이지 않는 항목

### 검증표
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| verify가 구현 전에 실패 | VM `bash scripts/verify/m1-01.sh` | 확인(VM): 5건 실패, exit 1 |
| pod 3개 Ready, 컨테이너 3개 request/limit, readinessProbe /ready, PVC 3개 Bound | verify | 확인(VM) |
| 세 백엔드 /ready 200 | verify (port-forward) | 확인(VM) |
| Tempo OTLP 1건 전송 → `/api/traces/<id>` 조회 | verify | 확인(VM) |
| Loki OTLP 로그 1건 전송 → `query_range` 조회, `\| trace_id="..."` structured metadata 필터로 조회 | verify | 확인(VM) |
| Mimir `/api/v1/push` 404 아님 | verify (빈 body로 400) | 확인(VM) |
| exemplar 설정 반영 | verify (`/config` max_global_exemplars_per_user=100000) | 확인(VM) |
| ingest storage 꺼짐, multitenancy 꺼짐 | verify (`/config`) | 확인(VM) |
| pod 3개 delete 후 재기동, /ready 200, 기존 trace/log 재조회(PVC 유지) | verify | 확인(VM) |
| Ingress 없음 | verify | 확인(VM) |
| `make clean && make` → exit 0, 재실행 exit 0, 그 뒤 verify exit 0 | VM | 확인(VM) |
| 로그 `level=error`: mimir 0, tempo 0, loki 1(`ratestore ... empty ring`, 기동 직후 1회) | VM `kubectl logs` | 확인(VM) |
| `bash -n`, shellcheck(warning 이상) | mac | 확인(mac 정적) |
| amd64 VM에서의 기동 | - | 미확인 (검증 VM은 aarch64) |
| OTLP→Mimir 경로의 exemplar 전달 | - | 미확인 (F-M1-04) |
| Tempo 3.1.0 monolithic에서 compaction 등 장기 동작 | - | 미확인 (기동 직후 `backend scheduler no jobs found` 경고/에러가 보였던 적이 있으나 최종 로그에서는 0건) |

### 실측 (VM, 기동 후 verify 직후)
`kubectl top pod -n observability`: loki-0 42Mi / mimir-0 59Mi / tempo-0 29Mi (CPU 4~6m). 부하 없는 상태의 값이다.
노드 allocatable (`kubectl describe node`): cpu 4, memory 8121856Ki (약 7.75Gi). 배포 후 Allocated: requests cpu 430m / memory 828Mi, limits cpu 2300m / memory 2314Mi (dummy와 k3s 시스템 pod 포함).
request: mimir 100m/256Mi, loki 50m/192Mi, tempo 50m/192Mi (limit: mimir 1Gi, 나머지 512Mi). 이후 compiler는 request 256Mi / limit 1Gi 예정. 이 값으로 예산 부족 여부는 판단하지 않았다.

### 안 된 것
- verify는 한 번 수정했다: Loki OTLP 성공 코드(204), 재기동 직후 첫 연결 실패에 대한 재시도, port-forward 포트 전체 대기. 검사 기준을 완화한 것이 아니라 기대값/타이밍 오류 수정이다
- 부하 상태 RAM 미측정

### 다음 단계
- F-M1-02: tracesToLogs는 customQuery로 structured metadata 필터 (`| trace_id="${__trace.traceId}" | span_id="${__span.spanId}"`). Loki에서 `| trace_id="..."` 필터가 동작함은 이번에 확인
- F-M1-02: Collector → Mimir `prometheusremotewrite` `http://mimir.observability:8080/api/v1/push`(send_exemplars/resource_to_telemetry 등은 버전 문서로 확인), Collector → Loki `otlphttp` `http://loki.observability:3100/otlp`, Collector → Tempo `otlp` `tempo.observability:4317`
- F-M1-02: Grafana datasource는 provisioning. multitenancy 꺼짐이라 X-Scope-OrgId 불필요

## F-M0-02 cluster-ingress-hosts (브랜치 feat/m0-02-cluster-ingress-hosts)

### 한 일
- `scripts/cluster.sh` (`make cluster`): `k3d cluster create lgtm --image $K3S_IMAGE --servers 1 --agents 0 -p 80:80@loadbalancer -p 443:443@loadbalancer -p 4001:4001/tcp@server:0:direct -p 4001:4001/udp@server:0:direct --wait --timeout 180s`. 이미 있으면 `[skip]`. 이후 node Ready(120s) → `deploy/traefik` 생성 polling(180s) → `rollout status deploy/traefik`(180s) → IngressClass `traefik` 확인. skip 경로에서도 동일하게 대기. 실패 시 단계 이름과 함께 exit 1
- `k8s/dummy/`: namespace `dummy`, 호스트 3개 각각 Deployment + Service + Ingress(traefik). 이미지 `hashicorp/http-echo:1.0.0`(amd64/arm64 확인), 본문 `lgtm-dummy` / `grafana-dummy` / `ipfs-dummy`, resources request/limit 지정. `make deploy`가 apply 후 Available 대기, `scripts/wait-ingress.sh`로 세 호스트가 200을 낼 때까지 대기(실제 deploy는 F-M1-01부터)
- `scripts/hosts.sh` (`make hosts`): `# BEGIN lgtm` / `# END lgtm` 블록. 재실행해도 1개, 이미 최신이면 `[skip]`
- `make status`(nodes -o wide, pods -A, ingress -A), `make clean`(클러스터 삭제, 없으면 `[skip]` exit 0, /etc/hosts 안 건드림)
- `scripts/verify/m0-02.sh` (실패 상태로 먼저 커밋, VM에서 15건 실패 확인)
- HANDOFF.md F-M0-01 중복 블록 정리 (`fix: HANDOFF duplicate block`)

### 검증표
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| verify가 구현 전에 실패 | VM `bash scripts/verify/m0-02.sh` | 확인(VM): 15건 실패, exit 1 |
| 노드 Ready, VERSION = K3S_IMAGE | verify (`kubectl get nodes`, 기대 `v1.37.1+k3s1`) | 확인(VM) |
| k3d v5.9.0이 k3s v1.37.1을 지원 | 실제 `--image`로 생성 후 위 검사 | 확인(VM). 공식 호환표는 없음 |
| 4001/tcp, 4001/udp 매핑 존재 | VM `docker port k3d-lgtm-server-0` → `4001/tcp -> 0.0.0.0:4001`, `4001/udp -> 0.0.0.0:4001` (+ `[::]`) | 확인(VM): **매핑 존재까지만**. 외부에서 실제로 닿는지는 F-M3-01 |
| 세 호스트 → 127.0.0.1 | verify (`getent hosts`) | 확인(VM) |
| 세 호스트 curl 200, 본문이 서로 다름 | verify (`curl`, `lgtm-dummy`/`grafana-dummy`/`ipfs-dummy`) | 확인(VM) |
| `make cluster` 재실행 skip, 클러스터 재생성 안 함 | verify | 확인(VM) |
| `make hosts` 재실행 후 블록 1개 | verify (BEGIN/END 각 1) | 확인(VM) |
| `dummy` namespace 컨테이너 3개 모두 request/limit | verify (jsonpath) | 확인(VM) |
| `make clean && make cluster && make deploy && make hosts` | VM 실행 | 확인(VM): exit 0 |
| `make clean && make cluster` 재생성 경로 | VM 실행 (여러 번) | 확인(VM): exit 0 |
| `make` 처음(클러스터 없음)부터 끝까지, 그리고 재실행 | VM `make` | 확인(VM): 둘 다 exit 0, 재실행 `[skip]` 6줄 |
| `make clean`이 클러스터 없을 때 통과, /etc/hosts 유지 | VM `make clean` 2회 연속 | 확인(VM): exit 0, hosts 블록 1개 유지 |
| `bash -n`, shellcheck(warning 이상), `make -n` | mac | 확인(mac 정적) |
| amd64 VM, 클러스터가 stopped 상태일 때 skip 경로 | - | 미확인 |

### 결정 / 주의
- `@server:0:direct`는 k3d 공식 문서(v5.9.0 cluster create 페이지)에 예시가 없다. 근거는 소스 `pkg/client/ports.go`(TransformPorts: `direct`는 지정한 단일 노드의 ports에 기록, 2개 이상이면 에러). 실제 동작은 위 `docker port`로 확인했다
- 4001은 생성 시점에만 매핑된다. 이미 있는 클러스터는 skip하므로 매핑을 바꾸려면 `make clean`
- 대기 방식 변경 이유: 생성 직후에는 `helm-install-traefik` job이 아직 없을 수 있어 `kubectl wait job/...`은 즉시 not found로 실패한다. 그래서 `deploy/traefik` 생성 polling → rollout status → IngressClass 순서로 했다(VM에서 helm-install-traefik이 1회 재시작했지만 통과)
- verify의 resources 검사는 `dummy` namespace로 한정. kube-system의 svclb/coredns 등 k3s가 띄우는 pod는 우리가 제어할 수 없어 검사하면 항상 실패한다 (PRD INF-08의 "모든 pod"는 우리가 만든 pod 기준으로 해석)
- 구현 중 발견: Deployment Available 직후에도 Traefik이 라우트를 반영하기 전에는 503이 나온다(첫 verify에서 lgtm/grafana 503). `make deploy`가 `scripts/wait-ingress.sh`로 200을 기다리게 해 해결. verify는 완화하지 않음

### 안 된 것
- 4001 외부 도달(NAT, 공유기 포트포워딩 포함)은 F-M3-01
- amd64 VM 미검증(검증한 VM은 arm64), stopped 클러스터 재시작 경로 없음(`make clean && make cluster`로 복구)
- 호스트 PC에서의 접속(README 옵션)은 이번 범위 밖

### 다음 단계
- F-M1-01: `make deploy`를 observability 스택 배포로 확장(더미 `grafana.lgtm.local`부터 교체)
- F-M3-01: 4001 외부 도달 검증
- README Instructions에 `sudo apt install -y make git` 사전 조건 명시 (F-M6-01)

## F-M0-01 skeleton-install (브랜치 feat/m0-01-skeleton-install)

### 한 일
- 디렉토리(backend/ frontend/ k8s/ dashboards/ scripts/verify/) + `.gitkeep`, `.gitignore`
- `Makefile`: 9.1 전 타겟. 미구현은 `TODO <피처ID>` 후 exit 0. 기본 타겟 `all = install cluster build deploy hosts`
- `scripts/install.sh`: docker(공식 apt repo, docker-buildx-plugin 포함, compose 제외), kubectl/helm/k3d. 버전은 Makefile 상단 변수. arch 자동 감지, kubectl/helm/k3d는 공식 checksum 검증, idempotent(`[skip] <tool> <ver>`)
- `scripts/with-docker.sh`: 재로그인 없이 docker 그룹 권한 사용. `sg docker -c` + POSIX single-quote quoting, `WITH_DOCKER_FORCE_SG=1`로 sg 경로 강제
- `scripts/verify/m0-01.sh` (실패하는 상태로 먼저 커밋)

### 고정 버전 (2026-10-21 web 확인)
| 도구 | 버전 | 비고 |
|---|---|---|
| k3d | v5.9.0 | 기본 k3s는 v1.35.5-k3s1(VM의 `k3d version`으로 확인). `K3S_IMAGE`로 최신 minor를 명시 고정 |
| k3s (`K3S_IMAGE`) | rancher/k3s:v1.37.1-k3s1 | F-M0-02에서 `k3d --image`로 사용. 이번 피처 미사용 |
| kubectl | v1.37.1 | k3s와 같은 minor |
| helm | v3.22.1 | Helm 3 선택 이유: Helm 4(v4.3.x)가 최신이지만 Mimir/Tempo/Loki 차트와 호환 검증이 안 돼서 3.x 최신 패치로 고정 |
| docker-ce / -cli | 5:29.9.1-1~debian.13~trixie | download.docker.com trixie pool의 amd64·arm64 양쪽에 있는 최신 |

### 된 것
- mac 정적: `bash -n`, shellcheck, `make -n` 전 타겟, TODO 타겟 exit 0, mac에서 install 거부
- VM(Debian 13 trixie, arm64, 2026-10-21): docker 미설치 상태에서 `make install` 1회차 exit 0, 같은 ssh 명령 안에서 `id -nG`에 docker 없음 / 직접 `docker info` 실패(direct=1) / 래퍼 경유 성공(wrapper=0) → INF-03 확인. 2회차 `make install`은 `[skip]` 4줄만. `scripts/verify/m0-01.sh` exit 0(PASS 40), `make` exit 0
- 개발 VM은 NOPASSWD sudo 사용 중, 클린 VM 검증(F-M6-02)은 이 설정 없이

### 안 된 것
- amd64 VM 미검증(검증한 VM은 arm64). sudo 비밀번호 경로 미검증
- 새 VM에는 `make`가 없을 수 있음(Makefile이 스스로 설치 불가): `sudo apt-get install -y make`를 먼저 해야 한다. F-M6-02/README에서 다룰 것
- checksum 불일치 경로 미테스트(정상 경로만 VM 확인)
- verify 스크립트 첫 버전은 설치 여부를 `dpkg-query -W` 성공으로 판정해 compose가 미설치인데도 실패했음 → Status 기준으로 수정(커밋됨)

### 다음 단계
- README Instructions에 `sudo apt install -y make git` 사전 조건 명시 (F-M6-01)

## VM 검증 절차
Debian 13 VM에서 그대로 복붙.

```bash
git fetch origin && git checkout feat/m0-01-skeleton-install && git pull

# 0) 새 VM이면 make 부터: sudo apt-get install -y make
# 1) 고정한 docker 버전이 실제로 설치 가능한지 재확인 (repo 추가 전이면 install 후 다시 실행)
#    install 이 repo 를 추가한다. 아래 출력에 5:29.9.1-1~debian.13~trixie 가 있어야 함
sudo apt-get update -qq; apt-cache madison docker-ce | head -5
curl -sI https://download.docker.com/linux/debian/dists/trixie/InRelease | head -1

make install
make install          # 두 번째: [skip] 4줄만, 다운로드/apt 로그 없어야 함
bash scripts/verify/m0-01.sh; echo "exit=$?"
make; echo "exit=$?"
```
참고: madison 단계는 docker repo 추가 전(첫 설치 전)에는 항목이 비어 있을 수 있다. 그 경우 `make install` 이 repo 를 추가한 뒤 위 madison 명령을 다시 실행해 값을 대조한다.
