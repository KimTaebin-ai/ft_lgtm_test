#!/usr/bin/env bash
# F-M1-02 collector-grafana 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
set -u

if [ "$(uname -s)" != "Linux" ]; then
	echo "FAIL: Linux(Debian VM)에서만 실행할 수 있습니다 (현재: $(uname -s)). VM에서 실행하세요." >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
info() { printf 'INFO: %s\n' "$1"; }
var() { make --no-print-directory -s "print-$1" 2>/dev/null; }

CLUSTER_NAME="$(var CLUSTER_NAME)"
CTX="k3d-${CLUSTER_NAME:-lgtm}"
NS="observability"
GRAFANA_HOST="grafana.lgtm.local"
SVC_NAME="verify-m1-02"
k() { kubectl --context "$CTX" "$@"; }

# 로컬 포트 (port-forward)
P_MIMIR=18080
P_LOKI=13100
P_TEMPO=13200
P_OTLP=14318

PF_PIDS=()
pf_stop() {
	local p
	for p in "${PF_PIDS[@]:-}"; do
		[ -n "$p" ] && kill "$p" 2>/dev/null
	done
	wait 2>/dev/null
	PF_PIDS=()
}
trap pf_stop EXIT INT TERM

# pf_start <svc> <local>:<remote>...
pf_start() {
	local svc="$1"; shift
	k -n "$NS" port-forward "svc/$svc" "$@" >/dev/null 2>&1 &
	PF_PIDS+=("$!")
	local m port
	for m in "$@"; do
		port="${m%%:*}"
		for _ in $(seq 1 30); do
			(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && continue 2
			sleep 1
		done
		return 1
	done
	return 0
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null; }
# Grafana 는 Ingress(Traefik) 경로로 호출한다. /etc/hosts 없이 --resolve 사용
gurl() { curl -s --max-time 10 --resolve "$GRAFANA_HOST:80:127.0.0.1" "$@"; }
# 인증 호출: 비밀번호는 stdin curl config 로만 넘겨 프로세스 목록/출력에 남기지 않는다
ADMIN_PW="$(k -n "$NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
gauth() { printf 'user = "admin:%s"\n' "$ADMIN_PW" | curl -s -K - --max-time 10 --resolve "$GRAFANA_HOST:80:127.0.0.1" "$@"; }
# pyj <python expr over d>  : stdin JSON 을 d 로 읽어 식을 출력. 실패 시 빈 문자열
pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }

# ---- 1. pod Ready + resources limit ----
for app in otel-collector grafana; do
	rd="$(k -n "$NS" get pods -l "app=$app" -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>&1 | grep -c '^True$')"
	[ "$rd" -ge 1 ] && pass "$app pod Ready" || fail "$app pod Ready 아님"
	res="$(k -n "$NS" get pods -l "app=$app" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{"|"}{.resources.requests.cpu}{"|"}{.resources.requests.memory}{"|"}{.resources.limits.cpu}{"|"}{.resources.limits.memory}{"\n"}{end}{end}' 2>&1)"
	bad="$(printf '%s\n' "$res" | grep . | awk -F'|' 'NF != 5 || $2=="" || $3=="" || $4=="" || $5==""')"
	if [ -n "$res" ] && [ -z "$bad" ]; then pass "$app resources request/limit 지정"; else fail "$app resources 누락: ${bad:-$res}"; fi
done

probe="$(k -n "$NS" get deploy otel-collector -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}' 2>&1)"
[ -n "$probe" ] && pass "Collector readinessProbe httpGet (port $probe, health_check)" || fail "Collector readinessProbe httpGet 없음"

# ---- 2. Collector config validate + 기동 로그 ----
cv="$(k -n "$NS" exec deploy/otel-collector -- /otelcol-contrib validate --config=/etc/otelcol/config.yaml 2>&1)"
cv_rc=$?
[ "$cv_rc" -eq 0 ] && pass "otelcol-contrib validate 성공" || fail "otelcol-contrib validate 실패: $cv"

# exporter 전송 실패("Exporting failed")는 제외한다: m1-01 이 mimir/loki/tempo 를 일부러 재시작하고,
# F-M1-04 부터 backend 가 5초마다 metric 을 보내 재시작 구간의 전송 실패가 error 로 남는다 (기동/설정 오류가 아님)
errn="$(k -n "$NS" logs deploy/otel-collector 2>&1 | grep -v 'Exporting failed' | grep -cE '"level":"error"|[[:space:]]error[[:space:]]|level=error')"
[ "${errn:-0}" -eq 0 ] && pass "Collector 기동 로그 error 0건" || fail "Collector 로그 error ${errn}건"

# ---- 3. Grafana health / anonymous ----
c=""
for _ in $(seq 1 30); do
	c="$(http_code --resolve "$GRAFANA_HOST:80:127.0.0.1" "http://$GRAFANA_HOST/api/health")"
	[ "$c" = "200" ] && break
	sleep 2
done
[ "$c" = "200" ] && pass "http://$GRAFANA_HOST/api/health 200 (Ingress 경유)" || fail "Grafana /api/health code=${c:-없음}"

c="$(http_code --resolve "$GRAFANA_HOST:80:127.0.0.1" "http://$GRAFANA_HOST/")"
[ "$c" = "200" ] && pass "인증 없이 홈 200 (login redirect 없음 = anonymous)" || fail "인증 없이 홈 code=${c:-없음} (200 아님)"
c="$(http_code --resolve "$GRAFANA_HOST:80:127.0.0.1" "http://$GRAFANA_HOST/api/search")"
[ "$c" = "200" ] && pass "인증 없이 /api/search 200" || fail "인증 없이 /api/search code=${c:-없음}"

[ -n "$ADMIN_PW" ] && pass "Secret grafana-admin 에서 admin 비밀번호 읽음 (값 비출력)" || fail "Secret grafana-admin admin-password 없음"
# anonymous 가 켜져 있으면 틀린 인증도 익명으로 처리되므로 admin 전용 API 로 확인한다 (익명 Editor 는 403)
c="$(printf 'user = "admin:admin"\n' | curl -s -o /dev/null -w '%{http_code}' -K - --max-time 10 --resolve "$GRAFANA_HOST:80:127.0.0.1" "http://$GRAFANA_HOST/api/admin/settings" 2>/dev/null)"
[ "$c" != "200" ] && pass "기본값 admin/admin 으로 admin API 불가 (code $c)" || fail "admin/admin 으로 admin API 200 — 기본 비밀번호가 살아 있음"
c2="$(gauth -o /dev/null -w '%{http_code}' "http://$GRAFANA_HOST/api/admin/settings")"
[ "$c2" = "200" ] && pass "Secret 비밀번호로 admin API 200" || fail "Secret 비밀번호 admin API code=${c2:-없음}"

# 실제 적용된 설정 (admin settings API). 값은 문자열 비교
settings="$(gauth "http://$GRAFANA_HOST/api/admin/settings")"
chk_setting() { # <section> <key> <expected>
	local got
	got="$(printf '%s' "$settings" | pyj "d['$1']['$2']")"
	[ "$got" = "$3" ] && pass "grafana 설정 $1.$2=$3" || fail "grafana 설정 $1.$2='${got}' (기대 $3)"
}
chk_setting auth.anonymous enabled true
chk_setting auth.anonymous org_role Editor
chk_setting auth disable_login_form true
chk_setting analytics reporting_enabled false
chk_setting analytics check_for_updates false
chk_setting analytics check_for_plugin_updates false
chk_setting news news_feed_enabled false
chk_setting plugins preinstall_auto_update false
chk_setting plugins preinstall_disabled true
chk_setting plugins plugin_admin_enabled false
chk_setting snapshots external_enabled false

# ---- 4. datasource 3개 + health ----
check_datasources() { # <라벨 접두>
	local u c h
	for u in mimir tempo loki; do
		c="$(gauth "http://$GRAFANA_HOST/api/datasources/uid/$u" | pyj "d['uid']")"
		[ "$c" = "$u" ] && pass "$1datasource uid=$u 존재" || { fail "$1datasource uid=$u 없음"; continue; }
		h=""
		for _ in $(seq 1 15); do
			h="$(gauth "http://$GRAFANA_HOST/api/datasources/uid/$u/health" | pyj "d['status']")"
			[ "$h" = "OK" ] && break
			sleep 2
		done
		[ "$h" = "OK" ] && pass "$1datasource $u health OK" || fail "$1datasource $u health='${h:-없음}'"
	done
}
check_datasources ""

# ---- 5. provisioning 결과 (correlation 설정) ----
ds_mimir="$(gauth "http://$GRAFANA_HOST/api/datasources/uid/mimir")"
ds_tempo="$(gauth "http://$GRAFANA_HOST/api/datasources/uid/tempo")"
ds_loki="$(gauth "http://$GRAFANA_HOST/api/datasources/uid/loki")"

v="$(printf '%s' "$ds_mimir" | pyj "d['jsonData']['exemplarTraceIdDestinations'][0]['datasourceUid']+'/'+d['jsonData']['exemplarTraceIdDestinations'][0]['name']")"
[ "$v" = "tempo/trace_id" ] && pass "mimir exemplarTraceIdDestinations → tempo / trace_id" || fail "mimir exemplarTraceIdDestinations='${v}'"

v="$(printf '%s' "$ds_tempo" | pyj "d['jsonData']['tracesToLogsV2']['datasourceUid']")"
[ "$v" = "loki" ] && pass "tempo tracesToLogsV2.datasourceUid=loki" || fail "tempo tracesToLogsV2.datasourceUid='${v}'"
v="$(printf '%s' "$ds_tempo" | pyj "d['jsonData']['tracesToLogsV2']['customQuery']")"
[ "$v" = "True" ] && pass "tempo tracesToLogsV2.customQuery=true" || fail "tempo tracesToLogsV2.customQuery='${v}'"
TL_QUERY="$(printf '%s' "$ds_tempo" | pyj "d['jsonData']['tracesToLogsV2']['query']")"
case "$TL_QUERY" in *span_id*trace_id* | *trace_id*span_id*) pass "tempo tracesToLogsV2.query 에 trace_id, span_id 필터: $TL_QUERY" ;; *) fail "tracesToLogsV2.query='${TL_QUERY}'" ;; esac
case "$TL_QUERY" in "{"*) pass "tracesToLogsV2.query 가 stream selector({...})로 시작" ;; *) fail "tracesToLogsV2.query 가 { 로 시작하지 않음 (LogQL parse error)" ;; esac
v="$(printf '%s' "$ds_tempo" | pyj "d['jsonData']['tracesToMetrics']['datasourceUid']")"
[ "$v" = "mimir" ] && pass "tempo tracesToMetrics.datasourceUid=mimir" || fail "tempo tracesToMetrics.datasourceUid='${v}'"
TM_KEY="$(printf '%s' "$ds_tempo" | pyj "d['jsonData']['tracesToMetrics']['tags'][0]['key']")"
TM_VAL="$(printf '%s' "$ds_tempo" | pyj "d['jsonData']['tracesToMetrics']['tags'][0].get('value','')")"

v="$(printf '%s' "$ds_loki" | pyj "d['jsonData']['derivedFields'][0]['matcherType']")"
[ "$v" = "label" ] && pass "loki derivedFields[0].matcherType=label" || fail "loki derivedFields[0].matcherType='${v}'"
v="$(printf '%s' "$ds_loki" | pyj "d['jsonData']['derivedFields'][0]['datasourceUid']+'/'+d['jsonData']['derivedFields'][0]['name']")"
[ "$v" = "tempo/trace_id" ] && pass "loki derivedFields → tempo / trace_id" || fail "loki derivedFields='${v}'"

# ---- 6. 파이프라인 smoke: Collector :4318 → Tempo / Loki / Mimir ----
pf_ok=1
pf_start otel-collector "$P_OTLP:4318" || pf_ok=0
pf_start mimir "$P_MIMIR:8080" || pf_ok=0
pf_start loki "$P_LOKI:3100" || pf_ok=0
pf_start tempo "$P_TEMPO:3200" || pf_ok=0
if [ "$pf_ok" -ne 1 ]; then fail "port-forward 시작 실패"; echo "RESULT: $fails 건 실패" >&2; exit 1; fi

now_ns="$(date +%s)000000000"
end_ns="$(( $(date +%s) + 1 ))000000000"
TRACE_ID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
SPAN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
RES="\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"$SVC_NAME\"}}]}"
otlp_post() { # <signal> <json>
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -d "$2" "http://127.0.0.1:$P_OTLP/v1/$1" 2>/dev/null
}
c="$(otlp_post traces "{\"resourceSpans\":[{$RES,\"scopeSpans\":[{\"scope\":{\"name\":\"verify\"},\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"verify-span\",\"kind\":1,\"startTimeUnixNano\":\"$now_ns\",\"endTimeUnixNano\":\"$end_ns\"}]}]}]}")"
[ "$c" = "200" ] && pass "Collector POST /v1/traces 200" || fail "Collector /v1/traces code=${c:-없음}"
c="$(otlp_post logs "{\"resourceLogs\":[{$RES,\"scopeLogs\":[{\"scope\":{\"name\":\"verify\"},\"logRecords\":[{\"timeUnixNano\":\"$now_ns\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"verify-m1-02 hello\"},\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\"}]}]}]}")"
[ "$c" = "200" ] && pass "Collector POST /v1/logs 200" || fail "Collector /v1/logs code=${c:-없음}"
# gauge: prometheusremotewrite 는 delta monotonic sum 을 버리므로 gauge 를 쓴다
c="$(otlp_post metrics "{\"resourceMetrics\":[{$RES,\"scopeMetrics\":[{\"scope\":{\"name\":\"verify\"},\"metrics\":[{\"name\":\"verify_m1_02_gauge\",\"gauge\":{\"dataPoints\":[{\"timeUnixNano\":\"$now_ns\",\"asDouble\":42}]}}]}]}]}")"
[ "$c" = "200" ] && pass "Collector POST /v1/metrics 200" || fail "Collector /v1/metrics code=${c:-없음}"

got=""
for _ in $(seq 1 30); do
	got="$(http_code "http://127.0.0.1:$P_TEMPO/api/traces/$TRACE_ID")"
	[ "$got" = "200" ] && break
	sleep 2
done
[ "$got" = "200" ] && pass "Collector→Tempo: /api/traces/<id> 조회" || fail "Tempo trace 조회 실패 code=${got:-없음}"

loki_query() { # <logql>
	curl -s --max-time 10 -G "http://127.0.0.1:$P_LOKI/loki/api/v1/query_range" \
		--data-urlencode "query=$1" \
		--data-urlencode "start=$(( $(date +%s) - 600 ))000000000" \
		--data-urlencode "end=$(( $(date +%s) + 60 ))000000000" 2>/dev/null
}
hit=0
for _ in $(seq 1 30); do
	hit="$(loki_query "{service_name=\"$SVC_NAME\"} | trace_id=\"$TRACE_ID\"" | grep -c 'verify-m1-02 hello')"
	[ "${hit:-0}" -ge 1 ] && break
	sleep 2
done
[ "${hit:-0}" -ge 1 ] && pass "Collector→Loki: | trace_id= structured metadata 필터로 조회" || fail "Loki | trace_id= 조회 0건"

# Tempo 가 provisioned 한 tracesToLogsV2.query 를 변수 치환해 Loki 에 직접 전송 (문법 오류 검출)
RENDERED="${TL_QUERY//\$\{__trace.traceId\}/$TRACE_ID}"
RENDERED="${RENDERED//\$\{__span.spanId\}/$SPAN_ID}"
info "tracesToLogsV2 query 치환 결과: $RENDERED"
case "$RENDERED" in *'${'*) fail "변수 치환 안 된 부분이 남음: $RENDERED" ;; esac
rbody="$(loki_query "$RENDERED")"
rstatus="$(printf '%s' "$rbody" | pyj "d['status']")"
rn="$(printf '%s' "$rbody" | pyj "sum(len(s['values']) for s in d['data']['result'])")"
if [ "$rstatus" = "success" ] && [ "$rn" = "1" ]; then pass "provisioned tracesToLogsV2.query 를 Loki query_range 로 실행 → 로그 1건"; else fail "tracesToLogsV2.query 실행 status='${rstatus}' 건수='${rn}' body=$(printf '%s' "$rbody" | head -c 300)"; fi

# Mimir: 실제 저장된 이름/label 세트 확인
series=""
for _ in $(seq 1 30); do
	series="$(curl -s --max-time 10 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/series" --data-urlencode 'match[]={__name__=~"verify_m1_02.*"}' --data-urlencode "start=$(( $(date +%s) - 600 ))" --data-urlencode "end=$(( $(date +%s) + 60 ))")"
	[ "$(printf '%s' "$series" | pyj "len(d['data'])")" = "1" ] && break
	sleep 2
done
stored="$(printf '%s' "$series" | pyj "d['data'][0]")"
if [ -n "$stored" ]; then pass "Collector→Mimir: 저장된 series 조회"; info "Mimir 저장 label 세트: $stored"; else fail "Mimir series 조회 실패: $series"; fi
qv="$(curl -s --max-time 10 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/query" --data-urlencode "query=verify_m1_02_gauge" | pyj "d['data']['result'][0]['value'][1]")"
[ "$qv" = "42" ] && pass "Mimir instant query verify_m1_02_gauge=42" || fail "Mimir instant query 값='${qv}'"

# tracesToMetrics 매핑: tags 의 value(Mimir label 이름)가 실제 저장 label 로 존재하고 값이 service.name 과 같은지
lbl="${TM_VAL:-$TM_KEY}"
lv="$(printf '%s' "$stored" | python3 -I -c "import ast,sys; d=ast.literal_eval(sys.stdin.read()); print(d.get(sys.argv[1],''))" "$lbl" 2>/dev/null)"
[ "$lv" = "$SVC_NAME" ] && pass "tracesToMetrics tags ${TM_KEY}→${lbl}: Mimir label ${lbl}=${lv}" || fail "tracesToMetrics tags ${TM_KEY}→${lbl}: Mimir label 값='${lv}' (기대 $SVC_NAME). 저장 세트: $stored"

# ---- 7. 외부 통신 시도 없음 ----
glog="$(k -n "$NS" logs deploy/grafana 2>&1)"
ext="$(printf '%s\n' "$glog" | grep -iE 'installing plugin|downloading|grafana\.com/(api|grafana/plugins)|stats\.grafana|api\.github\.com' | head -5)"
[ -z "$ext" ] && pass "Grafana 로그에 외부 다운로드/플러그인 설치 시도 없음" || fail "Grafana 로그에 외부 통신 흔적: $ext"

# ---- 8. 노출 범위 ----
ings="$(k -n "$NS" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep .)"
[ "$ings" = "grafana" ] && pass "namespace $NS Ingress 는 grafana 하나뿐 (Collector Ingress 없음)" || fail "namespace $NS Ingress 목록: ${ings:-없음}"
svct="$(k -n "$NS" get svc otel-collector -o jsonpath='{.spec.type}' 2>/dev/null)"
[ "$svct" = "ClusterIP" ] && pass "otel-collector Service ClusterIP" || fail "otel-collector Service type='${svct}'"

# ---- 9. Grafana pod 재기동 후에도 datasource 3개 유지 (PVC 없음, provisioning 소유) ----
pf_stop
npvc="$(k -n "$NS" get pvc --no-headers 2>/dev/null | grep -c '^grafana')"
[ "$npvc" -eq 0 ] && pass "Grafana PVC 없음" || fail "Grafana PVC ${npvc}개"
k -n "$NS" delete pod -l app=grafana --wait=true >/dev/null 2>&1
k -n "$NS" rollout status deploy/grafana --timeout=180s >/dev/null 2>&1 && pass "Grafana pod 삭제 후 rollout 완료" || fail "Grafana pod 삭제 후 rollout 미완료"
for _ in $(seq 1 30); do
	[ "$(http_code --resolve "$GRAFANA_HOST:80:127.0.0.1" "http://$GRAFANA_HOST/api/health")" = "200" ] && break
	sleep 2
done
check_datasources "재기동 후 "

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
