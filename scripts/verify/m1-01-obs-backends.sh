#!/usr/bin/env bash
# F-M1-01 obs-backends 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make deploy 가 끝난 상태.
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
var() { make --no-print-directory -s "print-$1" 2>/dev/null; }

CLUSTER_NAME="$(var CLUSTER_NAME)"
CTX="k3d-${CLUSTER_NAME:-lgtm}"
NS="observability"
k() { kubectl --context "$CTX" "$@"; }

# 로컬 포트 (port-forward). 서비스: mimir:8080, loki:3100, tempo:3200 + 4318
P_MIMIR=19080
P_LOKI=14100
P_TEMPO=14200
P_OTLP=15318


. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
trap pf_stop EXIT INT TERM
# pf_start <svc> <local>:<remote>...  (namespace $NS). HTTP 응답까지 확인한 뒤 반환 (lib-pf.sh)
pf_start() { pf_forward "$NS" "$1" "${@:2}"; }

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null; }

# ---- 1. pod / PVC / resources / readinessProbe ----
pods="$(k -n "$NS" get pods -l 'app in (mimir,loki,tempo)' --no-headers 2>&1)"
n="$(printf '%s\n' "$pods" | grep -c .)"
notready="$(k -n "$NS" get pods -l 'app in (mimir,loki,tempo)' -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null | grep -v '=True$')"
if [ "$n" -eq 3 ] && [ -z "$notready" ]; then pass "namespace $NS pod 3개 Ready"; else fail "pod 3개 Ready 아님 (pod ${n}개, Ready 아님: ${notready:-없음}): $pods"; fi

res="$(k -n "$NS" get pods -l 'app in (mimir,loki,tempo)' -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{"|"}{.resources.requests.cpu}{"|"}{.resources.requests.memory}{"|"}{.resources.limits.cpu}{"|"}{.resources.limits.memory}{"\n"}{end}{end}' 2>&1)"
rn="$(printf '%s\n' "$res" | grep -c .)"
bad="$(printf '%s\n' "$res" | grep . | awk -F'|' 'NF != 5 || $2=="" || $3=="" || $4=="" || $5==""')"
if [ "$rn" -ge 3 ] && [ -z "$bad" ]; then pass "컨테이너 $rn개 모두 resources request/limit 지정"; else fail "resources 누락 (컨테이너 ${rn}개): $bad"; fi

probe="$(k -n "$NS" get statefulset -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}{end}' 2>&1)"
pn="$(printf '%s\n' "$probe" | grep -c .)"
pbad="$(printf '%s\n' "$probe" | grep . | grep -v '|/ready$')"
if [ "$pn" -eq 3 ] && [ -z "$pbad" ]; then pass "StatefulSet 3개 readinessProbe httpGet /ready"; else fail "readinessProbe /ready 누락: $probe"; fi

pvc="$(k -n "$NS" get pvc --no-headers 2>&1)"
pvn="$(printf '%s\n' "$pvc" | grep -c .)"
pvb="$(printf '%s\n' "$pvc" | awk '$2=="Bound"' | grep -c .)"
if [ "$pvn" -eq 3 ] && [ "$pvb" -eq 3 ]; then pass "PVC 3개 Bound"; else fail "PVC 3개 Bound 아님 (전체 $pvn, Bound $pvb): $pvc"; fi

# ---- 2. /ready 200 ----
pf_ok=1
pf_start mimir "$P_MIMIR:8080" || pf_ok=0
pf_start loki "$P_LOKI:3100" || pf_ok=0
pf_start tempo "$P_TEMPO:3200" "$P_OTLP:4318" || pf_ok=0
if [ "$pf_ok" -ne 1 ]; then fail "port-forward 시작 실패"; echo "RESULT: $fails 건 실패" >&2; exit 1; fi

ready_check() { # <name> <port>
	local c _
	# port-forward 가 열린 직후 첫 연결은 실패할 수 있어 짧게 재시도한다
	for _ in $(seq 1 15); do
		c="$(http_code "http://127.0.0.1:$2/ready")"
		[ "$c" = "200" ] && break
		sleep 1
	done
	[ "$c" = "200" ] && pass "$1 /ready 200" || fail "$1 /ready code=${c:-없음}"
}
ready_check mimir "$P_MIMIR"
ready_check loki "$P_LOKI"
ready_check tempo "$P_TEMPO"

# ---- 3. Tempo OTLP smoke ----
now_ns="$(date +%s)000000000"
end_ns="$(( $(date +%s) + 1 ))000000000"
TRACE_ID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
SPAN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
trace_json="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-m1-01\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"verify\"},\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"verify-span\",\"kind\":1,\"startTimeUnixNano\":\"$now_ns\",\"endTimeUnixNano\":\"$end_ns\"}]}]}]}"
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -d "$trace_json" "http://127.0.0.1:$P_OTLP/v1/traces" 2>/dev/null)"
[ "$c" = "200" ] && pass "Tempo POST /v1/traces 200" || fail "Tempo POST /v1/traces code=${c:-없음}"

tempo_get() { # 조회 코드
	http_code "http://127.0.0.1:$P_TEMPO/api/traces/$TRACE_ID"
}
got=""
for _ in $(seq 1 30); do
	got="$(tempo_get)"
	[ "$got" = "200" ] && break
	sleep 2
done
[ "$got" = "200" ] && pass "Tempo /api/traces/<id> 로 trace 조회" || fail "Tempo trace 조회 실패 code=${got:-없음}"

# ---- 4. Loki OTLP smoke (structured metadata 필터까지) ----
LOG_TRACE_ID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
LOG_SPAN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
log_json="{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-m1-01\"}}]},\"scopeLogs\":[{\"scope\":{\"name\":\"verify\"},\"logRecords\":[{\"timeUnixNano\":\"$now_ns\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"verify-m1-01 hello\"},\"traceId\":\"$LOG_TRACE_ID\",\"spanId\":\"$LOG_SPAN_ID\"}]}]}]}"
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -d "$log_json" "http://127.0.0.1:$P_LOKI/otlp/v1/logs" 2>/dev/null)"
# Loki 는 성공 시 204 No Content 를 돌려준다
if [ "$c" = "200" ] || [ "$c" = "204" ]; then pass "Loki POST /otlp/v1/logs $c"; else fail "Loki POST /otlp/v1/logs code=${c:-없음}"; fi

loki_query() { # <logql>
	curl -s --max-time 10 -G "http://127.0.0.1:$P_LOKI/loki/api/v1/query_range" \
		--data-urlencode "query=$1" \
		--data-urlencode "start=$(( $(date +%s) - 600 ))000000000" \
		--data-urlencode "end=$(( $(date +%s) + 60 ))000000000" 2>/dev/null
}
body_hit=""
for _ in $(seq 1 30); do
	body_hit="$(loki_query '{service_name="verify-m1-01"} |= "verify-m1-01 hello"' | grep -c 'verify-m1-01 hello')"
	[ "${body_hit:-0}" -ge 1 ] && break
	sleep 2
done
[ "${body_hit:-0}" -ge 1 ] && pass "Loki query_range 로 로그 조회" || fail "Loki 로그 조회 실패"

# 본문 검색이 아니라 structured metadata(trace_id)로 필터되는지: PRD 8.5 Trace→Logs customQuery 전제
sm_hit="$(loki_query "{service_name=\"verify-m1-01\"} | trace_id=\"$LOG_TRACE_ID\"" | grep -c 'verify-m1-01 hello')"
[ "${sm_hit:-0}" -ge 1 ] && pass "Loki structured metadata 필터(| trace_id=\"...\") 로 조회" || fail "Loki structured metadata trace_id 필터 0건"

# ---- 5. Mimir ----
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/x-protobuf' -H 'Content-Encoding: snappy' --data-binary '' "http://127.0.0.1:$P_MIMIR/api/v1/push" 2>/dev/null)"
if [ -n "$c" ] && [ "$c" != "000" ] && [ "$c" != "404" ]; then pass "Mimir POST /api/v1/push 경로 존재 (code $c, 404 아님)"; else fail "Mimir POST /api/v1/push code=${c:-없음}"; fi

cfg="$(curl -s --max-time 10 "http://127.0.0.1:$P_MIMIR/config" 2>/dev/null)"
ex="$(printf '%s\n' "$cfg" | awk '/^ *max_global_exemplars_per_user:/ {print $2; exit}')"
if [ -n "$ex" ] && [ "$ex" -gt 0 ] 2>/dev/null; then pass "Mimir /config max_global_exemplars_per_user=$ex"; else fail "Mimir /config max_global_exemplars_per_user='${ex:-없음}' (0 이하이거나 반영 안 됨)"; fi

ing="$(printf '%s\n' "$cfg" | awk '/^ingest_storage:/ {f=1; next} f && /^ *enabled:/ {print $2; exit}')"
[ "$ing" = "false" ] && pass "Mimir /config ingest_storage.enabled=false (classic)" || fail "Mimir ingest_storage.enabled='${ing:-없음}'"

mt="$(printf '%s\n' "$cfg" | awk '/^multitenancy_enabled:/ {print $2; exit}')"
[ "$mt" = "false" ] && pass "Mimir /config multitenancy_enabled=false" || fail "Mimir multitenancy_enabled='${mt:-없음}'"

# ---- 6. 외부 노출 없음 ----
# F-M1-02 부터 같은 namespace 에 Grafana Ingress 가 있다. backend 3종을 가리키는 Ingress 만 센다
ing_n="$(k -n "$NS" get ingress -o jsonpath='{range .items[*]}{range .spec.rules[*].http.paths[*]}{.backend.service.name}{"\n"}{end}{end}' 2>/dev/null | grep -cE '^(mimir|loki|tempo)$')"
[ "$ing_n" -eq 0 ] && pass "mimir/loki/tempo 를 가리키는 Ingress 없음" || fail "backend 를 가리키는 Ingress ${ing_n}개"

# ---- 7. pod 재기동 후에도 /ready 200, PVC 데이터 유지 ----
pf_stop
k -n "$NS" delete pod tempo-0 loki-0 mimir-0 --wait=true >/dev/null 2>&1
rc=0
for s in mimir loki tempo; do
	k -n "$NS" rollout status "statefulset/$s" --timeout=180s >/dev/null 2>&1 || rc=1
done
[ "$rc" -eq 0 ] && pass "pod 삭제 후 StatefulSet 3개 rollout 완료" || fail "pod 삭제 후 rollout 미완료"

pf_ok=1
pf_start mimir "$P_MIMIR:8080" || pf_ok=0
pf_start loki "$P_LOKI:3100" || pf_ok=0
pf_start tempo "$P_TEMPO:3200" || pf_ok=0
if [ "$pf_ok" -eq 1 ]; then
	ready_check "재기동 후 mimir" "$P_MIMIR"
	ready_check "재기동 후 loki" "$P_LOKI"
	ready_check "재기동 후 tempo" "$P_TEMPO"
	got=""
	for _ in $(seq 1 30); do
		got="$(tempo_get)"
		[ "$got" = "200" ] && break
		sleep 2
	done
	[ "$got" = "200" ] && pass "재기동 후 Tempo 에서 기존 trace 조회 (PVC 유지)" || fail "재기동 후 Tempo trace 조회 실패 code=${got:-없음}"
	sm_hit="$(loki_query "{service_name=\"verify-m1-01\"} | trace_id=\"$LOG_TRACE_ID\"" | grep -c 'verify-m1-01 hello')"
	[ "${sm_hit:-0}" -ge 1 ] && pass "재기동 후 Loki 에서 기존 로그 조회 (PVC 유지)" || fail "재기동 후 Loki 로그 조회 0건"
else
	fail "재기동 후 port-forward 시작 실패"
fi

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
