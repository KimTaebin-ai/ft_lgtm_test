#!/usr/bin/env bash
# F-M1-04 metrics-exemplar 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# 이전 피처 회귀(m1-01 ~ m1-03)는 make verify-m1 이 순서대로 실행한다 (여기서는 호출하지 않는다).
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
k() { kubectl --context "$CTX" "$@"; }

P_MIMIR=22080
P_TEMPO=17200

# PRD 8.2 bucket 경계 (+Inf 포함)
WANT_LE='["+Inf", "0.05", "0.1", "0.25", "0.5", "1", "10", "2", "20", "3", "4", "4.5", "5", "5.5"]'

LOAD_ERR="$(mktemp)"
. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
trap 'pf_stop; rm -f "$LOAD_ERR"' EXIT INT TERM
# pf_start <svc> <local>:<remote>...  (namespace observability). HTTP 응답까지 확인한 뒤 반환 (lib-pf.sh)
pf_start() { pf_forward observability "$1" "${@:2}"; }

pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }

mimir() { # <api-path> [curl -G 인자...]  → /prometheus/api/v1/<path>
	local p="$1"; shift
	curl -s --max-time 15 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/$p" "$@"
}
now() { date +%s; }
series() { # <selector> → series 배열 JSON ([{label:value,...}, ...])
	mimir series --data-urlencode "match[]=$1" \
		--data-urlencode "start=$(($(now) - 900))" --data-urlencode "end=$(($(now) + 60))" | pyj "json.dumps(d['data'])"
}
poll_series() { # <selector> → 최대 60s 폴링, 마지막 결과 출력
	local out="[]" i
	for i in $(seq 1 30); do
		out="$(series "$1")"
		[ -n "$out" ] && [ "$out" != "[]" ] && break
		sleep 2
	done
	printf '%s' "${out:-[]}"
}

# ---- 1. load.sh: 정상 ≥5, __slow__ ≥2, __fail_compile__ ≥2 ----
[ -x scripts/load.sh ] && pass "scripts/load.sh 존재" || fail "scripts/load.sh 없음/실행권한 없음"
LOAD_OUT="$(bash scripts/load.sh --ok 6 --slow 2 --fail 2 2>"$LOAD_ERR")"
load_rc=$?
[ "$load_rc" = "0" ] && pass "load.sh 단발 모드 종료 0 ($(cat "$LOAD_ERR"))" || fail "load.sh 실패 rc=$load_rc ($(cat "$LOAD_ERR"))"
cnt() { printf '%s\n' "$LOAD_OUT" | awk -v k="$1" -v s="$2" '$1==k && ($2==s || s=="*") {n++} END{print n+0}'; }
n_ok="$(cnt ok success)"; n_slow="$(cnt slow success)"; n_fail="$(cnt fail compile_error)"
[ "$n_ok" -ge 5 ] && pass "정상 요청 success ${n_ok}건" || fail "정상 요청 success ${n_ok}건 (기대 ≥5)"
[ "$n_slow" -ge 2 ] && pass "__slow__ 요청 success ${n_slow}건" || fail "__slow__ 요청 success ${n_slow}건 (기대 ≥2)"
[ "$n_fail" -ge 2 ] && pass "__fail_compile__ 요청 compile_error ${n_fail}건" || fail "__fail_compile__ 요청 compile_error ${n_fail}건 (기대 ≥2)"
TRACE_IDS="$(printf '%s\n' "$LOAD_OUT" | awk 'length($3)==32 {print $3}')"

pf_ok=1
pf_start mimir "$P_MIMIR:8080" || pf_ok=0
pf_start tempo "$P_TEMPO:3200" || pf_ok=0
[ "$pf_ok" = "1" ] || fail "port-forward (mimir/tempo) 실패"

# ---- 2. Mimir 에 저장된 metric 이름 (reader 5s + collector batch 를 위해 10s 이상 대기) ----
info "export 대기 12s"
sleep 12
EXE="$(poll_series 'lgtm_executions_total')"
DUR="$(poll_series 'lgtm_execution_duration_seconds_bucket')"
STG="$(poll_series 'lgtm_stage_duration_seconds_bucket')"
for pair in "lgtm_executions_total:$EXE" "lgtm_execution_duration_seconds_bucket:$DUR" "lgtm_stage_duration_seconds_bucket:$STG"; do
	name="${pair%%:*}"; data="${pair#*:}"
	v="$(printf '%s' "$data" | pyj "len(d)")"
	[ "${v:-0}" -ge 1 ] 2>/dev/null && pass "Mimir series $name (${v}개)" || fail "Mimir series $name 없음"
done
v="$(mimir label/__name__/values --data-urlencode "match[]={__name__=~\"lgtm_.*\"}" \
	--data-urlencode "start=$(($(now) - 900))" --data-urlencode "end=$(($(now) + 60))" | pyj "sorted(d['data'])")"
info "Mimir lgtm_* 이름: $v"

# ---- 3. lgtm_executions_total status ----
for st in success compile_error; do
	v="$(mimir query --data-urlencode "query=sum(lgtm_executions_total{status=\"$st\"})" | pyj "d['data']['result'][0]['value'][1]")"
	ok="$(python3 -I -c 'import sys; print(1 if float(sys.argv[1] or 0) > 0 else 0)' "${v:-0}" 2>/dev/null)"
	[ "$ok" = "1" ] && pass "lgtm_executions_total{status=\"$st\"} = $v (> 0)" || fail "lgtm_executions_total{status=\"$st\"} = '${v}'"
done

# ---- 4. bucket le 집합 ----
for pair in "execution_duration:$DUR" "stage_duration:$STG"; do
	name="${pair%%:*}"; data="${pair#*:}"
	v="$(printf '%s' "$data" | pyj "sorted(set(s['le'] for s in d if 'le' in s))")"
	want="$(python3 -I -c 'import json,sys; print(sorted(json.loads(sys.argv[1])))' "$WANT_LE")"
	[ "$v" = "$want" ] && pass "lgtm_${name}_seconds le 집합 == PRD bucket" || fail "lgtm_${name}_seconds le='${v}' (기대 ${want})"
done

# ---- 4b. label 세트 (PRD 8.2) ----
lab() { printf '%s' "$1" | pyj "sorted(set(k for s in d for k in s if k not in ('__name__','le','job','instance','service_name','service_instance_id','otel_scope_name','otel_scope_version','otel_scope_schema_url','exported_job','exported_instance')))"; }
v="$(lab "$EXE")"; [ "$v" = "['language', 'status']" ] && pass "executions label: $v" || fail "executions label='${v}' (기대 ['language', 'status'])"
v="$(lab "$DUR")"; [ "$v" = "['language', 'status']" ] && pass "execution_duration label: $v" || fail "execution_duration label='${v}'"
v="$(lab "$STG")"; [ "$v" = "['stage']" ] && pass "stage_duration label: $v" || fail "stage_duration label='${v}' (기대 ['stage'])"
v="$(printf '%s %s %s' "$EXE" "$DUR" "$STG" | grep -o -i '"[a-z_]*\(cid\|hash\|sha\)[a-z0-9_]*"' | sort -u | tr '\n' ' ')"
[ -z "$v" ] && pass "label 키에 cid/hash/sha 류 없음" || fail "high-cardinality 의심 label 키: $v"
v="$(printf '%s' "$STG" | pyj "sorted(set(s['stage'] for s in d))")"
[ "$v" = "['compile', 'execute', 'ipfs_upload']" ] && pass "stage 값: $v" || fail "stage 값='${v}'"

# ---- 5. exemplar: Mimir query_exemplars ----
EX_JSON=""; EX_IDS=""
for _ in $(seq 1 30); do
	EX_JSON="$(mimir query_exemplars --data-urlencode 'query=lgtm_execution_duration_seconds_bucket' \
		--data-urlencode "start=$(($(now) - 900))" --data-urlencode "end=$(($(now) + 60))")"
	EX_IDS="$(printf '%s' "$EX_JSON" | pyj "'\n'.join(sorted(set(e['labels']['trace_id'] for r in d['data'] for e in r['exemplars'] if 'trace_id' in e['labels'])))")"
	[ -n "$EX_IDS" ] && break
	sleep 2
done
v="$(printf '%s' "$EX_JSON" | pyj "sorted(set(k for r in d['data'] for e in r['exemplars'] for k in e['labels']))")"
info "exemplar label 키: ${v:-없음}"
[ -n "$EX_IDS" ] && pass "query_exemplars 가 trace_id 라벨을 반환 ($(printf '%s\n' "$EX_IDS" | wc -l)개)" || fail "query_exemplars 에 trace_id 라벨 없음 (응답: $(printf '%s' "$EX_JSON" | head -c 300))"
MATCH="$(comm -12 <(printf '%s\n' "$EX_IDS" | sort -u) <(printf '%s\n' "$TRACE_IDS" | sort -u) | head -1)"
[ -n "$MATCH" ] && pass "exemplar trace_id 가 load.sh 응답 trace_id 와 일치: $MATCH" || fail "exemplar trace_id 중 load.sh 응답과 일치하는 것이 없음"
# Grafana datasource 설정과 실측 키 일치
GKEY="$(grep -A1 'exemplarTraceIdDestinations' k8s/observability/grafana.yaml | grep -o 'name: [a-z_]*' | head -1 | cut -d' ' -f2)"
case "$v" in *"'$GKEY'"*) pass "Grafana exemplarTraceIdDestinations.name='$GKEY' 가 실측 exemplar 라벨 키와 일치" ;; *) fail "Grafana name='${GKEY}' 와 실측 키 $v 불일치" ;; esac

# ---- 6. 그 trace_id 가 Tempo 에서 조회됨 ----
if [ -n "$MATCH" ]; then
	code=000
	for _ in $(seq 1 15); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$MATCH")"
		[ "$code" = "200" ] && break
		sleep 2
	done
	[ "$code" = "200" ] && pass "Tempo 에서 trace $MATCH 조회됨" || fail "Tempo trace 조회 HTTP $code"
else
	fail "일치하는 trace_id 가 없어 Tempo 조회 생략"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m1-04)"; exit 0; fi
echo "FAILED: ${fails}건 (m1-04)" >&2
exit 1
