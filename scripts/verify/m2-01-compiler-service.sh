#!/usr/bin/env bash
# compiler-service 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# 15초 timeout 은 VM 에서 결정적으로 재현하기 어려워 단위 테스트(느린 명령 주입, 프로세스 그룹 kill 포함)로 대체한다 (아래 8번).
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

P_TEMPO=18200
P_COMPILER=23081
TMP="$(mktemp -d)"

. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
PF_LOG_DIR="$TMP"
# 6b 에서 compiler 를 scale 0 으로 내리므로, 중단/실패해도 종료 시 항상 1 로 복구한다 (idempotent)
cleanup() { pf_stop; k -n "$NS" scale deploy/compiler --replicas=1 >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# pf_start <ns> <svc 이름 | pod/이름> <local>:<remote>  (로그: $TMP/pf-<local>.log)
# svc/ 로 붙으면 시작 시점의 pod 하나에 고정되므로, compiler 는 호출 쪽에서 pod/<이름> 을 넘긴다.
# HTTP 응답까지 확인한 뒤 반환한다 (lib-pf.sh)
pf_start() { pf_forward "$1" "$2" "$3"; }
pf_kill() { pf_stop; }

# compiler_pod_ready: app=compiler pod 가 Ready 인 새 pod 하나만 남을 때까지(Terminating 포함) 기다리고 이름을 출력한다
compiler_pod_ready() {
	local i lines n name del ready
	for i in $(seq 1 120); do
		lines="$(k -n "$NS" get pod -l app=compiler -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
		n="$(printf '%s\n' "$lines" | grep -c .)"
		if [ "$n" = "1" ]; then
			IFS='|' read -r name del ready <<<"$lines"
			if [ -z "$del" ] && [ "$ready" = "true" ]; then printf '%s' "$name"; return 0; fi
		fi
		sleep 1
	done
	return 1
}
# compiler_debug: 실패 시 pod 상태와 port-forward 로그를 출력한다
compiler_debug() {
	echo "--- DEBUG kubectl get pods -l app=compiler -o wide" >&2
	k -n "$NS" get pods -l app=compiler -o wide >&2
	echo "--- DEBUG port-forward 로그 ($TMP/pf-$P_COMPILER.log)" >&2
	cat "$TMP/pf-$P_COMPILER.log" >&2 2>/dev/null
}

lurl() { curl -s --max-time 60 --resolve "$HOST:80:127.0.0.1" "$@"; }
pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }
now_s() { date +%s.%N; }
elapsed() { python3 -I -c 'import sys; print("%.2f" % (float(sys.argv[2])-float(sys.argv[1])))' "$1" "$2"; }

# Tempo trace → span 목록(서비스 이름 포함)
SUMMARIZE='import base64,json,sys
def hx(s):
    if not s: return ""
    if len(s) in (16,32) and all(c in "0123456789abcdefABCDEF" for c in s): return s.lower()
    return base64.b64decode(s).hex()
d=json.load(sys.stdin)
rs=d.get("batches") or d.get("resourceSpans") or []
out=[]
for b in rs:
    svc=""
    for a in (b.get("resource") or {}).get("attributes", []):
        if a["key"]=="service.name": svc=list(a["value"].values())[0]
    for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
        for s in ss.get("spans", []):
            code=(s.get("status") or {}).get("code", 0)
            out.append({"name": s["name"], "id": hx(s["spanId"]), "parent": hx(s.get("parentSpanId","")),
                        "service": svc, "error": code in (2, "2", "STATUS_CODE_ERROR")})
print(json.dumps(out))'
tempo_spans() { # <trace_id> <기대 span 수> → 최대 60s 폴링
	local tid="$1" want="$2" out="" n=0 i
	for i in $(seq 1 30); do
		out="$(curl -s --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$tid" | python3 -I -c "$SUMMARIZE" 2>/dev/null)"
		n="$(printf '%s' "$out" | pyj "len(d)")"
		[ "${n:-0}" -ge "$want" ] 2>/dev/null && break
		sleep 2
	done
	printf '%s' "$out"
}

# ---- 1. compiler pod Ready + resources ----
ready="$(k -n "$NS" get pod -l app=compiler -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
[ -n "$ready" ] && [ "$(printf '%s\n' "$ready" | grep -vc '^true$')" = "0" ] && pass "compiler pod Ready" || fail "compiler pod Ready 아님 (ready='${ready}')"
lim="$(k -n "$NS" get deploy compiler -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}/{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
[ "$lim" = "2/2Gi" ] && pass "compiler limit cpu/memory = $lim" || fail "compiler limit='${lim}' (기대 2/2Gi)"
req="$(k -n "$NS" get deploy compiler -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null)"
[ "$req" = "256Mi" ] && pass "compiler request memory = $req" || fail "compiler request memory='${req}' (기대 256Mi)"
img="$(k -n "$NS" get deploy compiler -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
case "$img" in lgtm-compiler:src-*) pass "compiler 이미지 태그 고정: $img" ;; *) fail "compiler 이미지 태그 부적절 ('${img}')" ;; esac
n_ing="$(k -n "$NS" get ingress -o jsonpath='{range .items[*]}{.spec.rules[*].http.paths[*].backend.service.name}{"\n"}{end}' 2>/dev/null | grep -c '^compiler$')"
[ "$n_ing" = "0" ] && pass "compiler Ingress 없음 (ClusterIP only)" || fail "compiler 를 가리키는 Ingress 가 있음"

compile() { # <소스> <출력 파일> → HTTP 코드 출력
	printf '%s' "$1" | curl -s --max-time 60 --retry 10 --retry-connrefused --retry-delay 1 -o "$2" -w '%{http_code}' -X POST -H 'Content-Type: text/plain' --data-binary @- "http://127.0.0.1:$P_COMPILER/compile"
}
compile_file() { # <소스 파일> <출력 파일>
	curl -s --max-time 60 --retry 10 --retry-connrefused --retry-delay 1 -o "$2" -w '%{http_code}' -X POST -H 'Content-Type: text/plain' --data-binary @"$1" "http://127.0.0.1:$P_COMPILER/compile"
}
CODE_OK='fn main() { println!("hello"); }'
CODE_BAD='fn main() { let x = ; }'

# ---- 2. POST /compile 정상 (cold → warm) ----
# pod 를 재시작해 첫 compile 이 cold(page cache, rustc 첫 로드) 가 되게 한다
k -n "$NS" rollout restart deploy/compiler >/dev/null 2>&1
k -n "$NS" rollout status deploy/compiler --timeout=120s >/dev/null 2>&1 || fail "compiler 재시작 후 rollout 실패"
CPOD="$(compiler_pod_ready)" || { fail "compiler 새 pod 하나만 Ready 로 남지 않음"; compiler_debug; }
pf_start "$NS" "pod/$CPOD" "$P_COMPILER:8080" || { fail "port-forward (compiler, 재시작 후) 실패"; compiler_debug; }
pf_start observability tempo "$P_TEMPO:3200" || fail "port-forward (tempo, 재시작 후) 실패"

t0=$(now_s); c="$(compile "$CODE_OK" "$TMP/cold.wasm")"; t1=$(now_s)
COLD="$(elapsed "$t0" "$t1")"
[ "$c" = "200" ] && pass "POST /compile (cold) → 200 (${COLD}s)" || { fail "POST /compile (cold) HTTP ${c}"; compiler_debug; }
magic="$(head -c4 "$TMP/cold.wasm" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
[ "$magic" = "0061736d" ] && pass "응답 앞 4바이트 \\0asm ($(wc -c <"$TMP/cold.wasm") bytes)" || fail "응답 앞 4바이트='${magic}' (기대 0061736d)"
t0=$(now_s); c="$(compile "$CODE_OK" "$TMP/warm.wasm")"; t1=$(now_s)
WARM="$(elapsed "$t0" "$t1")"
[ "$c" = "200" ] && pass "POST /compile (warm) → 200 (${WARM}s)" || fail "POST /compile (warm) HTTP ${c}"
info "compile 시간 cold=${COLD}s warm=${WARM}s"

# ---- 3. 문법 오류 → rustc 에러 메시지 ----
c="$(compile "$CODE_BAD" "$TMP/bad.txt")"
[ "$c" = "422" ] && pass "문법 오류 → HTTP 422" || fail "문법 오류 HTTP ${c} (기대 422)"
grep -q 'error' "$TMP/bad.txt" && pass "응답 본문에 rustc 에러 메시지: $(head -1 "$TMP/bad.txt")" || fail "응답 본문에 'error' 없음: $(head -c 200 "$TMP/bad.txt")"

# ---- 4. 요청 후 작업 디렉토리 비어 있음 (성공·실패 모두) ----
left="$(k -n "$NS" exec deploy/compiler -- ls -A /work 2>&1)"
[ -z "$left" ] && pass "요청 후 /work 비어 있음 (성공+실패 요청 이후)" || fail "/work 에 잔여물: $left"

# ---- 5. /api/execute 정상 → success + trace(서비스 2개, rustc parent = compile) ----
req_body() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$1"; }
post() { req_body "$1" | lurl -X POST -H 'Content-Type: application/json' --data-binary @- "http://$HOST/api/execute"; }
OK_BODY="$(post "$CODE_OK")"
v="$(printf '%s' "$OK_BODY" | pyj "d['status']")"
[ "$v" = "success" ] && pass "/api/execute 예제 → success" || fail "/api/execute status='${v}' body=$(printf '%s' "$OK_BODY" | head -c 200)"
TID="$(printf '%s' "$OK_BODY" | pyj "d['trace_id']")"
SPANS="$(tempo_spans "$TID" 5)"
v="$(printf '%s' "$SPANS" | pyj "sorted(set(s['service'] for s in d))")"
[ "$v" = "['lgtm-backend', 'lgtm-compiler']" ] && pass "Tempo trace service 2개: $v" || fail "Tempo trace service='${v}'"
v="$(printf '%s' "$SPANS" | pyj "[s['parent'] for s in d if s['name']=='rustc' and s['service']=='lgtm-compiler'][0]")"
cid="$(printf '%s' "$SPANS" | pyj "[s['id'] for s in d if s['name']=='compile' and s['service']=='lgtm-backend'][0]")"
[ -n "$v" ] && [ "$v" = "$cid" ] && pass "rustc span 의 parent == backend compile span ($cid)" || fail "rustc parent='${v}' compile id='${cid}'"

# ---- 6. /api/execute 문법 오류 → compile_error + rustc 메시지 ----
BAD_BODY="$(post "$CODE_BAD")"
v="$(printf '%s' "$BAD_BODY" | pyj "d['status']")"
[ "$v" = "compile_error" ] && pass "/api/execute 문법 오류 → compile_error" || fail "/api/execute status='${v}'"
v="$(printf '%s' "$BAD_BODY" | pyj "'y' if 'error' in d['stderr'] and 'stub' not in d['stderr'] else ''")"
[ "$v" = "y" ] && pass "stderr 에 rustc 메시지" || fail "stderr='$(printf '%s' "$BAD_BODY" | pyj "d.get('stderr')" | head -c 200)'"

# ---- 6b. compiler 다운 → internal_error (HTTP 200, 플랫폼 장애는 compile_error 와 구분) ----
k -n "$NS" scale deploy/compiler --replicas=0 >/dev/null 2>&1
k -n "$NS" wait --for=delete pod -l app=compiler --timeout=60s >/dev/null 2>&1
pf_kill
DOWN_CODE="$(req_body "$CODE_OK" | lurl -o "$TMP/down.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- "http://$HOST/api/execute")"
DOWN_BODY="$(cat "$TMP/down.json" 2>/dev/null)"
v="$(printf '%s' "$DOWN_BODY" | pyj "d['status']")"
[ "$DOWN_CODE" = "200" ] && [ "$v" = "internal_error" ] && pass "compiler 다운 → HTTP 200 internal_error" || fail "compiler 다운: HTTP ${DOWN_CODE} status='${v}'"
v="$(printf '%s' "$DOWN_BODY" | pyj "'y' if d.get('message') else ''")"
[ "$v" = "y" ] && pass "internal_error message 에 요약 있음" || fail "internal_error message 없음"
DTID="$(printf '%s' "$DOWN_BODY" | pyj "d['trace_id']")"
pf_start observability tempo "$P_TEMPO:3200" || fail "port-forward (tempo, 다운 검사) 실패"
DSPANS="$(tempo_spans "$DTID" 3)"
v="$(printf '%s' "$DSPANS" | pyj "[s['error'] for s in d if s['name']=='POST /api/execute'][0]")"
[ "$v" = "True" ] && pass "internal_error 의 root span 이 ERROR" || fail "root span error='${v}'"
k -n "$NS" scale deploy/compiler --replicas=1 >/dev/null 2>&1
# scale 직후 rollout status 는 새 pod 가 생기기 전에 성공을 돌려줄 수 있어, 새 pod 하나만 Ready 로 남을 때까지 기다린다
CPOD="$(compiler_pod_ready)" || { fail "compiler 복구: 새 pod 하나만 Ready 로 남지 않음"; compiler_debug; }
pf_start "$NS" "pod/$CPOD" "$P_COMPILER:8080" || { fail "port-forward (compiler, 복구 후) 실패"; compiler_debug; }

# ---- 7. 동시 3건 compile → 전부 완료, 최대 동시 2 (로그의 started/finished 로 확인) ----
python3 -I -c '
n = 1500
print("\n".join("fn f%d(x: u64) -> u64 { x.wrapping_mul(%d).wrapping_add(%d) }" % (i, i + 3, i) for i in range(n)))
print("fn main() { let mut s = 0u64;")
print("\n".join("s = f%d(s);" % i for i in range(n)))
print("println!(\"{}\", s); }")' >"$TMP/slow.rs"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
par_pids=()
for i in 1 2 3; do
	( t0=$(now_s); c="$(compile_file "$TMP/slow.rs" "$TMP/par$i.wasm")"; t1=$(now_s); echo "$c $(elapsed "$t0" "$t1")" >"$TMP/par$i.res" ) &
	par_pids+=("$!")
done
wait "${par_pids[@]}" # 인자 없는 wait 는 백그라운드 port-forward 까지 기다려 영원히 막힌다
done_n=0
for i in 1 2 3; do
	read -r c dt <"$TMP/par$i.res"
	[ "$c" = "200" ] && done_n=$((done_n + 1))
	info "동시 요청 $i: HTTP $c ${dt}s"
done
[ "$done_n" = "3" ] && pass "동시 3건 compile 전부 200" || { fail "동시 3건 중 ${done_n}건만 200"; compiler_debug; }
k -n "$NS" logs deploy/compiler --since-time="$SINCE" 2>/dev/null >"$TMP/compiler.log"
PEAK="$(python3 -I -c '
import json,sys
ev=[]
for l in open(sys.argv[1]):
    try: d=json.loads(l)
    except Exception: continue
    if d.get("msg") in ("compile started","compile finished") and d.get("time"):
        ev.append((d["time"], 1 if d["msg"]=="compile started" else -1))
ev.sort(key=lambda e:(e[0], e[1]))   # 같은 시각이면 finished(-1) 먼저
cur=peak=0
for _,x in ev:
    cur+=x; peak=max(peak,cur)
print(len([e for e in ev if e[1]==1]), peak)' "$TMP/compiler.log")"
set -- $PEAK
[ "${1:-0}" = "3" ] && pass "compiler 로그에 compile started 3건" || fail "compile started ${1:-0}건 (기대 3)"
[ "${2:-0}" = "2" ] && pass "동시 실행 peak = 2 (2+1 직렬화 흔적)" || fail "동시 실행 peak=${2:-?} (기대 2)"

# ---- 8. 15초 timeout / 프로세스 그룹 kill / semaphore: 단위 테스트로 대체 ----
info "15s timeout 은 VM 에서 결정적 재현이 어려워 단위 테스트(느린 명령 주입)로 대체한다"
if "$ROOT/scripts/lib/with-docker.sh" docker run --rm -v "$ROOT/backend:/src" -w /src -e GOTOOLCHAIN=local \
	golang:1.27.3-trixie go test -count=1 ./cmd/compiler/... ./internal/... >"$TMP/gotest.log" 2>&1; then
	pass "go test (timeout·그룹 kill·temp 삭제·semaphore·backend handler) 통과"
else
	fail "go test 실패: $(tail -20 "$TMP/gotest.log")"
fi

# 회귀(verify-m1 등)는 make verify 가 순서대로 실행한다 (verify 스크립트는 다른 verify 스크립트를 호출하지 않는다).

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m2-01)"; exit 0; fi
echo "FAILED: ${fails}건 (m2-01)" >&2
exit 1
