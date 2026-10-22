#!/usr/bin/env bash
# F-M1-03 backend-skeleton 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
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
NS="lgtm"
HOST="lgtm.local"
k() { kubectl --context "$CTX" "$@"; }

P_LOKI=16100
P_TEMPO=16200


. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
trap pf_stop EXIT INT TERM
# pf_start <svc> <local>:<remote>...  (namespace observability). HTTP 응답까지 확인한 뒤 반환 (lib-pf.sh)
pf_start() { pf_forward observability "$1" "${@:2}"; }

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null; }
# Ingress(Traefik) 경유. /etc/hosts 없이 --resolve 사용
lurl() { curl -s --max-time 15 --resolve "$HOST:80:127.0.0.1" "$@"; }
pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }

# Tempo trace JSON 을 요약: span 목록(이름/id/parent/status/events/attrs)을 hex id 로 정규화해 JSON 으로 출력
SUMMARIZE='import base64,json,sys
def hx(s):
    if not s: return ""
    if len(s) in (16,32) and all(c in "0123456789abcdefABCDEF" for c in s): return s.lower()
    return base64.b64decode(s).hex()
d=json.load(sys.stdin)
rs=d.get("batches") or d.get("resourceSpans") or []
out=[]
for b in rs:
    for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
        for s in ss.get("spans", []):
            code=(s.get("status") or {}).get("code", 0)
            err = code in (2, "2", "STATUS_CODE_ERROR")
            attrs={a["key"]: list(a["value"].values())[0] for a in s.get("attributes", [])}
            out.append({"name": s["name"], "id": hx(s["spanId"]), "parent": hx(s.get("parentSpanId","")),
                        "error": err, "events": [e["name"] for e in s.get("events", [])], "attrs": attrs})
print(json.dumps(out))'

# ---- 1. backend pod Ready + resources limit ----
ready="$(k -n "$NS" get pod -l app=backend -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
[ -n "$ready" ] && [ "$(printf '%s\n' "$ready" | grep -vc '^true$')" = "0" ] && pass "backend pod Ready" || fail "backend pod Ready 아님 (ready='${ready}')"
lim="$(k -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}/{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
case "$lim" in */?*) pass "backend resources limit cpu/memory: $lim" ;; *) fail "backend resources limit 없음 ('${lim}')" ;; esac
req="$(k -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}/{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null)"
case "$req" in */?*) pass "backend resources request cpu/memory: $req" ;; *) fail "backend resources request 없음 ('${req}')" ;; esac
img="$(k -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
case "$img" in "" | *:latest | *:) fail "backend 이미지 태그 부적절 ('${img}')" ;; *) pass "backend 이미지 태그 고정: $img" ;; esac
pp="$(k -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null)"
[ "$pp" = "IfNotPresent" ] && pass "imagePullPolicy=IfNotPresent" || fail "imagePullPolicy='${pp}'"

# ---- 2. 정상 요청 → 200 + 6.2 필드 ----
CODE_OK='fn main() { println!("hello"); }'
req_body() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$1"; }
post() { # <code> → body 파일 경로를 BODY_OUT, 코드를 HTTP_CODE 에 설정
	BODY_OUT="$(mktemp)"
	HTTP_CODE="$(req_body "$1" | lurl -o "$BODY_OUT" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- "http://$HOST/api/execute")"
}
post "$CODE_OK"
OK_BODY="$(cat "$BODY_OUT")"; rm -f "$BODY_OUT"
[ "$HTTP_CODE" = "200" ] && pass "POST /api/execute 정상 코드 → 200" || fail "POST /api/execute HTTP ${HTTP_CODE} body=$(printf '%s' "$OK_BODY" | head -c 200)"
for f in status stdout stderr truncated cid ipfs_url trace_id; do
	v="$(printf '%s' "$OK_BODY" | pyj "'y' if '$f' in d else ''")"
	[ "$v" = "y" ] && pass "응답 필드 $f" || fail "응답 필드 $f 없음"
done
for f in compile execute ipfs_upload; do
	v="$(printf '%s' "$OK_BODY" | pyj "'y' if isinstance(d['timings_ms']['$f'], (int, float)) else ''")"
	[ "$v" = "y" ] && pass "응답 필드 timings_ms.$f" || fail "응답 필드 timings_ms.$f 없음"
done
v="$(printf '%s' "$OK_BODY" | pyj "d['status']")"
[ "$v" = "success" ] && pass "status=success" || fail "status='${v}'"
TRACE_ID="$(printf '%s' "$OK_BODY" | pyj "d['trace_id']")"
[ "${#TRACE_ID}" = "32" ] && pass "trace_id 32자 hex" || fail "trace_id='${TRACE_ID}'"

# ---- 3. Tempo: span 5개 (F-M2-01: compiler 의 rustc span 추가), root 이름, parent, TR-03 attribute ----
pf_ok=1
pf_start loki "$P_LOKI:3100" || pf_ok=0
pf_start tempo "$P_TEMPO:3200" || pf_ok=0
[ "$pf_ok" = "1" ] || fail "port-forward (loki/tempo) 실패"

tempo_spans() { # <trace_id> <기대 span 수> → 최대 60s 폴링 후 요약 JSON 출력
	local tid="$1" want="$2" out="" n=0 i
	for i in $(seq 1 30); do
		out="$(curl -s --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$tid" | python3 -I -c "$SUMMARIZE" 2>/dev/null)"
		n="$(printf '%s' "$out" | pyj "len(d)")"
		[ "${n:-0}" -ge "$want" ] 2>/dev/null && break
		sleep 2
	done
	printf '%s' "$out"
}

SPANS="$(tempo_spans "$TRACE_ID" 5)"
n="$(printf '%s' "$SPANS" | pyj "len(d)")"
[ "$n" = "5" ] && pass "Tempo: span 5개" || fail "Tempo: span 수='${n}' (기대 5)"
ROOT_NAME="$(printf '%s' "$SPANS" | pyj "[s['name'] for s in d if not s['parent']][0]")"
[ "$ROOT_NAME" = "POST /api/execute" ] && pass "root span 이름 정확히 'POST /api/execute'" || fail "root span 이름='${ROOT_NAME}'"
v="$(printf '%s' "$SPANS" | pyj "sorted(s['name'] for s in d if s['parent'])")"
[ "$v" = "['compile', 'execute', 'ipfs.upload', 'rustc']" ] && pass "자식 span: $v" || fail "자식 span='${v}'"
v="$(printf '%s' "$SPANS" | pyj "all(s['parent']==[r for r in d if not r['parent']][0]['id'] for s in d if s['parent'] and s['name']!='rustc')")"
[ "$v" = "True" ] && pass "rustc 를 뺀 나머지 3개의 parent = root" || fail "parent 관계 불일치 ($v)"
for a in code.sha256 code.language code.size_bytes; do
	v="$(printf '%s' "$SPANS" | pyj "'y' if '$a' in [s for s in d if not s['parent']][0]['attrs'] else ''")"
	[ "$v" = "y" ] && pass "root attribute $a" || fail "root attribute $a 없음"
done
v="$(printf '%s' "$SPANS" | pyj "'y' if [s for s in d if s['name']=='ipfs.upload'][0]['attrs'].get('ipfs.cid') else ''")"
[ "$v" = "y" ] && pass "ipfs.upload attribute ipfs.cid" || fail "ipfs.upload attribute ipfs.cid 없음"
v="$(printf '%s' "$SPANS" | pyj "any(s['error'] for s in d)")"
[ "$v" = "False" ] && pass "정상 요청은 ERROR span 없음" || fail "정상 요청에 ERROR span 존재"

# ---- 4. Loki: trace_id, compile span_id 필터 ----
loki_count() { # <logql>
	curl -s --max-time 10 -G "http://127.0.0.1:$P_LOKI/loki/api/v1/query_range" \
		--data-urlencode "query=$1" --data-urlencode "limit=100" \
		--data-urlencode "start=$(($(date +%s) - 900))000000000" --data-urlencode "end=$(($(date +%s) + 60))000000000" |
		pyj "sum(len(r['values']) for r in d['data']['result'])"
}
poll_loki() { # <logql> → 최대 60s 폴링, 건수 출력
	local c=0 i
	for i in $(seq 1 30); do
		c="$(loki_count "$1")"
		[ "${c:-0}" -ge 1 ] 2>/dev/null && break
		sleep 2
	done
	printf '%s' "${c:-0}"
}
c="$(poll_loki "{service_name=\"lgtm-backend\"} | trace_id=\"$TRACE_ID\"")"
[ "$c" -ge 1 ] 2>/dev/null && pass "Loki: trace_id 로그 ${c}건" || fail "Loki: trace_id 로그 ${c}건"
COMPILE_ID="$(printf '%s' "$SPANS" | pyj "[s['id'] for s in d if s['name']=='compile'][0]")"
c="$(poll_loki "{service_name=\"lgtm-backend\"} | trace_id=\"$TRACE_ID\" | span_id=\"$COMPILE_ID\"")"
[ "$c" -ge 1 ] 2>/dev/null && pass "Loki: compile span_id 로그 ${c}건" || fail "Loki: compile span_id 로그 ${c}건"
for sp in execute ipfs.upload; do
	sid="$(printf '%s' "$SPANS" | pyj "[s['id'] for s in d if s['name']=='$sp'][0]")"
	c="$(poll_loki "{service_name=\"lgtm-backend\"} | trace_id=\"$TRACE_ID\" | span_id=\"$sid\"")"
	[ "$c" -ge 1 ] 2>/dev/null && pass "Loki: $sp span_id 로그 ${c}건" || fail "Loki: $sp span_id 로그 ${c}건"
done

# ---- 5. kubectl logs JSON 한 줄에 같은 trace_id ----
line="$(k -n "$NS" logs deploy/backend --tail=500 2>/dev/null | grep "\"trace_id\":\"$TRACE_ID\"" | head -1)"
if [ -n "$line" ]; then
	v="$(printf '%s' "$line" | pyj "'y' if d.get('trace_id')=='$TRACE_ID' and d.get('span_id') else ''")"
	[ "$v" = "y" ] && pass "kubectl logs JSON 에 trace_id + span_id" || fail "kubectl logs JSON 형식 이상: $line"
else
	fail "kubectl logs 에서 trace_id=$TRACE_ID JSON 줄을 찾지 못함"
fi

# ---- 6. __fail_compile__ ----
post 'fn main() { let x = ; /* __fail_compile__ */ }'
FAIL_BODY="$(cat "$BODY_OUT")"; rm -f "$BODY_OUT"
[ "$HTTP_CODE" = "200" ] && pass "__fail_compile__ → HTTP 200" || fail "__fail_compile__ HTTP ${HTTP_CODE}"
v="$(printf '%s' "$FAIL_BODY" | pyj "d['status']")"
[ "$v" = "compile_error" ] && pass "status=compile_error" || fail "status='${v}'"
v="$(printf '%s' "$FAIL_BODY" | pyj "'y' if d.get('message') else ''")"
[ "$v" = "y" ] && pass "compile_error 에 message 존재" || fail "compile_error 에 message 없음"
FTID="$(printf '%s' "$FAIL_BODY" | pyj "d['trace_id']")"
FSPANS="$(tempo_spans "$FTID" 4)"
v="$(printf '%s' "$FSPANS" | pyj "[s['error'] for s in d if s['name']=='compile'][0]")"
[ "$v" = "True" ] && pass "compile span status ERROR" || fail "compile span error='${v}'"
v="$(printf '%s' "$FSPANS" | pyj "[s['error'] for s in d if s['name']=='POST /api/execute'][0]")"
[ "$v" = "True" ] && pass "root span status ERROR" || fail "root span error='${v}'"
v="$(printf '%s' "$FSPANS" | pyj "'y' if [s for s in d if s['name']=='compile'][0]['events'] else ''")"
[ "$v" = "y" ] && pass "compile span 에 error event" || fail "compile span event 없음"
v="$(printf '%s' "$FSPANS" | pyj "'y' if [s for s in d if s['name']=='POST /api/execute'][0]['events'] else ''")"
[ "$v" = "y" ] && pass "root span 에 error event" || fail "root span event 없음"
v="$(printf '%s' "$FSPANS" | pyj "sorted(s['name'] for s in d)")"
[ "$v" = "['POST /api/execute', 'compile', 'ipfs.upload', 'rustc']" ] && pass "compile 실패 trace span 4개 (execute 생략, ipfs.upload 수행)" || fail "compile 실패 trace span='${v}'"

# ---- 7. 느린 요청 (실제 1.5초 busy loop Rust): 전체 2~3초 ----
t0=$(date +%s.%N)
post 'fn main() { let t = std::time::Instant::now(); while t.elapsed().as_millis() < 1500 {} }'
t1=$(date +%s.%N)
rm -f "$BODY_OUT"
dt="$(python3 -I -c 'import sys; print(float(sys.argv[2])-float(sys.argv[1]))' "$t0" "$t1")"
ok="$(python3 -I -c 'import sys; print(1 if 2.0 <= float(sys.argv[1]) <= 3.5 else 0)' "$dt")"
[ "$HTTP_CODE" = "200" ] && [ "$ok" = "1" ] && pass "느린 요청 소요 ${dt}s (2~3.5s 허용)" || fail "느린 요청 HTTP ${HTTP_CODE} 소요 ${dt}s"

# ---- 8. 회귀: lgtm.local / 은 frontend(F-M4-01 이후), /healthz 는 backend 가 아니다 (frontend SPA fallback) ----
root_body="$(lurl "http://$HOST/")"
[ "$(lurl -o /dev/null -w '%{http_code}' "http://$HOST/")" = "200" ] && pass "lgtm.local / → 200" || fail "lgtm.local / 200 아님"
case "$root_body" in *'id="root"'*) pass "lgtm.local / 본문이 frontend HTML" ;; *) fail "lgtm.local / 본문='${root_body}'" ;; esac
hz_body="$(lurl "http://$HOST/healthz")"
case "$hz_body" in
	*'id="root"'*) pass "lgtm.local/healthz 본문이 frontend fallback HTML (backend healthz 아님, Ingress 미노출)" ;;
	*) fail "lgtm.local/healthz 본문='${hz_body}' (frontend HTML 아님: backend 노출 의심)" ;;
esac

# 이전 피처(m1-01, m1-02) 회귀는 make verify 가 순서대로 실행한다 (verify 스크립트는 다른 verify 스크립트를 호출하지 않는다).

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m1-03)"; exit 0; fi
echo "FAILED: ${fails}건 (m1-03)" >&2
exit 1
