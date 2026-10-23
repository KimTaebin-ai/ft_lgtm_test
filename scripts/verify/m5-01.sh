#!/usr/bin/env bash
# F-M5-01 instrumentation 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다 (jq 없음).
# status 별 요청을 보내고 Tempo trace / Loki 로그 / Mimir 지표를 PRD 8.2, 8.3 과 대조한다.
#  - span 구성, ERROR status, error event(message 하나, 512바이트 이하), TR-03/TR-04 attribute 가 응답과 일치
#  - span status/event/로그 어디에도 사용자 입력에서 나온 문자열(식별자, panic 메시지)이 없다. 메시지는 분류형 문구만 쓴다
#  - lgtm_output_bytes, histogram bucket 이 PRD 8.2 와 같다, lgtm_* label 에 cid/sha/trace 가 없다, exemplar 가 trace_id 를 가진다
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
HOST="lgtm.local"
URL="http://$HOST/api/execute"

P_MIMIR=27080
P_LOKI=27100
P_TEMPO=27200
TMP="$(mktemp -d)"

. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
PF_LOG_DIR="$TMP"
cleanup() { pf_stop; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }
field() { pyj "$2" <"$TMP/$1.json"; } # field <이름> <파이썬 식 (d=응답)>
mkreq() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$2" >"$TMP/$1.req"; }
send() { # send <이름> : 응답 JSON 은 $TMP/<이름>.json, HTTP 코드는 .code
	curl -s --max-time 90 --resolve "$HOST:80:127.0.0.1" -o "$TMP/$1.json" -w '%{http_code}' \
		-X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$1.req" "$URL" >"$TMP/$1.code"
}
rand() { head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ---- 0. 요청 7종. 고유 토큰은 식별자 / panic 메시지 / 문자열 리터럴에 넣는다 ----
T_OK="uniqok$(rand)"; T_CE="uniqce$(rand)"; T_DN="uniqdn$(rand)"; T_RT="uniqrt$(rand)"
T_EX="uniqex$(rand)"; T_TO="uniqto$(rand)"; T_ML="uniqml$(rand)"
CASES="ok ce dn rt ex to ml"
SRC_ok="fn main() { let s = \"$T_OK\"; println!(\"{}\", s.len()); }"
SRC_ce="fn main() { let x = $T_CE; }"
SRC_dn="fn main() { println!(\"{}\", env!(\"$T_DN\")); }"
SRC_rt="fn $T_RT() { panic!(\"$T_RT panic message\"); } fn main() { $T_RT(); }"
SRC_ex="fn main() { let s = \"$T_EX\"; if s.len() > 0 { std::process::exit(3); } }"
SRC_to="fn main() { let s = \"$T_TO\"; loop { if s.is_empty() { break; } } }"
SRC_ml="fn main() { let s = \"$T_ML\"; let v = vec![0u8; 100_000_000]; println!(\"{}{}\", s, v[5]); }"
tok_of() { case "$1" in ok) echo "$T_OK";; ce) echo "$T_CE";; dn) echo "$T_DN";; rt) echo "$T_RT";; ex) echo "$T_EX";; to) echo "$T_TO";; ml) echo "$T_ML";; esac; }
src_of() { eval "printf '%s' \"\$SRC_$1\""; }

# 케이스별 기대값 (분석기에 JSON 으로 전달)
# spans: 있어야 하는 span / err: ERROR 여야 하는 span / msg: ERROR span 의 status·event 메시지 정규식
# exit: execute 의 exec.exit_code (zero|nonzero|N) / rustc: rustc span 기대
SPEC_ROOT='"POST /api/execute"'
SPEC_ALL="[$SPEC_ROOT,\"compile\",\"rustc\",\"execute\",\"ipfs.upload\"]"
SPEC_NOEXEC="[$SPEC_ROOT,\"compile\",\"rustc\",\"ipfs.upload\"]"
SPEC_ok="{\"status\":\"success\",\"spans\":$SPEC_ALL,\"err\":[],\"exit\":\"zero\",\"rustc\":{\"outcome\":\"ok\",\"exit_code\":\"zero\"}}"
SPEC_ce="{\"status\":\"compile_error\",\"spans\":$SPEC_NOEXEC,\"err\":[$SPEC_ROOT,\"compile\",\"rustc\"],\"msg\":\"^rustc failed( \\\\[E[0-9]{4}\\\\])?\$\",\"rustc\":{\"outcome\":\"compile_error\",\"exit_code\":\"nonzero\"}}"
SPEC_dn="{\"status\":\"compile_error\",\"spans\":$SPEC_NOEXEC,\"err\":[$SPEC_ROOT,\"compile\",\"rustc\"],\"msg\":\"^source denied \\\\[deny-[a-z-]+\\\\]\$\",\"rustc\":{\"outcome\":\"denied\",\"exit_code\":\"absent\",\"rule\":\"deny-env-macro\"}}"
SPEC_rt="{\"status\":\"runtime_error\",\"spans\":$SPEC_ALL,\"err\":[$SPEC_ROOT,\"execute\"],\"msg\":\"^(exit code [0-9]+|wasm trap \\\\[[^]]+\\\\])\$\",\"exit\":\"nonzero\",\"rustc\":{\"outcome\":\"ok\",\"exit_code\":\"zero\"}}"
SPEC_ex="{\"status\":\"runtime_error\",\"spans\":$SPEC_ALL,\"err\":[$SPEC_ROOT,\"execute\"],\"msg\":\"^exit code 3\$\",\"exit\":\"3\",\"rustc\":{\"outcome\":\"ok\",\"exit_code\":\"zero\"}}"
SPEC_to="{\"status\":\"timeout\",\"spans\":$SPEC_ALL,\"err\":[$SPEC_ROOT,\"execute\"],\"msg\":\"^time limit exceeded\$\",\"exit\":\"any\",\"rustc\":{\"outcome\":\"ok\",\"exit_code\":\"zero\"}}"
SPEC_ml="{\"status\":\"memory_limit\",\"spans\":$SPEC_ALL,\"err\":[$SPEC_ROOT,\"execute\"],\"msg\":\"^memory limit exceeded\$\",\"exit\":\"any\",\"rustc\":{\"outcome\":\"ok\",\"exit_code\":\"zero\"}}"

# ---- 분석기: <trace.json> <response.json> <code 파일> <spec JSON> <토큰> → "OK: ..." / "NG: ..." 줄 ----
ANALYZE='import json, sys, re, hashlib
trace = json.load(open(sys.argv[1])); resp = json.load(open(sys.argv[2]))
code = json.load(open(sys.argv[3]))["code"]; spec = json.loads(sys.argv[4]); tok = sys.argv[5]
raw = open(sys.argv[1]).read()
def val(v):
    for k in ("intValue", "boolValue", "stringValue", "doubleValue"):
        if k in v:
            return int(v[k]) if k == "intValue" else v[k]
spans = []
for b in trace.get("batches") or trace.get("resourceSpans") or []:
    for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
        for s in ss.get("spans", []):
            st = s.get("status") or {}
            sc = st.get("code")
            spans.append({"name": s["name"], "root": not s.get("parentSpanId"),
                "attr": {a["key"]: val(a["value"]) for a in s.get("attributes", [])},
                "err": sc in (2, "STATUS_CODE_ERROR"), "smsg": st.get("message", ""),
                "events": [{"name": e.get("name"), "attr": {a["key"]: val(a["value"]) for a in e.get("attributes", [])}} for e in s.get("events", [])]})
def out(ok, msg): print(("OK: " if ok else "NG: ") + msg)
names = sorted(s["name"] for s in spans)
out(names == sorted(spec["spans"]), "span 구성 %s (기대 %s)" % (names, sorted(spec["spans"])))
roots = [s for s in spans if s["root"]]
out(len(roots) == 1 and roots[0]["name"] == "POST /api/execute", "root span 1개, 이름 POST /api/execute")
by = {}
for s in spans: by.setdefault(s["name"], s)
errs = sorted(s["name"] for s in spans if s["err"])
out(errs == sorted(spec["err"]), "ERROR span %s (기대 %s)" % (errs, sorted(spec["err"])))
rx = re.compile(spec["msg"]) if spec.get("msg") else None
for s in spans:
    if not s["err"]: continue
    ev = [e for e in s["events"] if e["name"] == "exception"]
    out(len(ev) == 1, "%s: error event 1개" % s["name"])
    if not ev: continue
    keys = sorted(ev[0]["attr"])
    out(keys == ["exception.message"], "%s: event attribute 는 exception.message 하나 %s" % (s["name"], keys))
    m = ev[0]["attr"].get("exception.message") or ""
    out(0 < len(m.encode()) <= 512 and 0 < len(s["smsg"].encode()) <= 512, "%s: event/status 메시지 1~512바이트 (%d/%d)" % (s["name"], len(m.encode()), len(s["smsg"].encode())))
    if rx: out(bool(rx.match(m)) and bool(rx.match(s["smsg"])), "%s: 분류형 문구 %r / %r" % (s["name"], m, s["smsg"]))
out(resp.get("status") == spec["status"], "응답 status=%s (기대 %s)" % (resp.get("status"), spec["status"]))
r = by.get("POST /api/execute", {"attr": {}})["attr"]
out(r.get("code.sha256") == hashlib.sha256(code.encode()).hexdigest(), "root code.sha256 일치")
out(r.get("code.language") == "rust", "root code.language=rust")
out(r.get("code.size_bytes") == len(code.encode()), "root code.size_bytes=%s (기대 %d)" % (r.get("code.size_bytes"), len(code.encode())))
out(r.get("ipfs.cid") == resp.get("cid") and bool(resp.get("cid")), "root ipfs.cid = 응답 cid")
out(r.get("lgtm.status") == resp.get("status"), "root lgtm.status=%s = 응답 status" % r.get("lgtm.status"))
if "execute" in by:
    e = by["execute"]["attr"]
    for k in ("exec.exit_code", "exec.timed_out", "exec.output_truncated", "exec.memory_limited"):
        out(k in e, "execute %s 존재" % k)
    out(e.get("exec.output_truncated") == bool(resp.get("truncated")), "exec.output_truncated=%s = 응답 truncated=%s" % (e.get("exec.output_truncated"), resp.get("truncated")))
    out(e.get("exec.timed_out") == (spec["status"] == "timeout"), "exec.timed_out=%s" % e.get("exec.timed_out"))
    out(e.get("exec.memory_limited") == (spec["status"] == "memory_limit"), "exec.memory_limited=%s" % e.get("exec.memory_limited"))
    x, want = e.get("exec.exit_code"), spec.get("exit")
    ok = {"zero": x == 0, "nonzero": isinstance(x, int) and x != 0, "any": isinstance(x, int)}.get(want, x == (int(want) if want and want.lstrip("-").isdigit() else None))
    out(ok, "exec.exit_code=%s (기대 %s)" % (x, want))
if "rustc" in by:
    a = by["rustc"]["attr"]; w = spec["rustc"]
    out(a.get("rustc.outcome") == w["outcome"], "rustc.outcome=%s (기대 %s)" % (a.get("rustc.outcome"), w["outcome"]))
    c = a.get("rustc.exit_code")
    out({"zero": c == 0, "nonzero": isinstance(c, int) and c != 0, "absent": c is None}[w["exit_code"]], "rustc.exit_code=%s (기대 %s)" % (c, w["exit_code"]))
    if w.get("rule"): out(a.get("denylist.rule") == w["rule"], "rustc denylist.rule=%s" % a.get("denylist.rule"))
out(tok not in raw.lower(), "trace 원문 전체에 고유 토큰 없음 (%s)" % tok)'

# ---- 1. 전제, port-forward ----
pf_forward observability mimir "$P_MIMIR:8080" || fail "port-forward (mimir) 실패"
pf_forward observability loki "$P_LOKI:3100" || fail "port-forward (loki) 실패"
pf_forward observability tempo "$P_TEMPO:3200" || fail "port-forward (tempo) 실패"

# ---- 2. 요청 전송 ----
for c in $CASES; do
	mkreq "$c" "$(src_of "$c")"
	send "$c"
	code="$(cat "$TMP/$c.code")"
	[ "$code" = "200" ] && pass "[$c] HTTP 200, status=$(field "$c" "d['status']")" || fail "[$c] HTTP '$code' body=$(head -c 300 "$TMP/$c.json")"
	python3 -I -c 'import json,sys; print(json.dumps({"code":sys.argv[1]}))' "$(src_of "$c")" >"$TMP/$c.code.json"
done

# ---- 3. Tempo: 케이스별 trace 분석 ----
fetch_trace() { # <trace_id> <out> : 기대 span 수가 모일 때까지 최대 60s 폴링 (root 와 ipfs.upload 가 보이면 종료)
	local i
	for i in $(seq 1 30); do
		curl -s --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$1" >"$2"
		grep -q '"ipfs.upload"' "$2" && grep -q '"POST /api/execute"' "$2" && return 0
		sleep 2
	done
	return 1
}
for c in $CASES; do
	tid="$(field "$c" "d['trace_id']")"
	spec="$(eval "printf '%s' \"\$SPEC_$c\"")"
	if [ -z "$tid" ] || ! fetch_trace "$tid" "$TMP/$c.trace"; then
		fail "[$c] Tempo trace 를 가져오지 못함 (trace_id='$tid')"
		continue
	fi
	python3 -I -c "$ANALYZE" "$TMP/$c.trace" "$TMP/$c.json" "$TMP/$c.code.json" "$spec" "$(tok_of "$c")" >"$TMP/$c.an" 2>"$TMP/$c.an.err"
	if [ ! -s "$TMP/$c.an" ]; then fail "[$c] 분석기 실패: $(head -c 300 "$TMP/$c.an.err")"; continue; fi
	while IFS= read -r line; do
		case "$line" in
		"OK: "*) pass "[$c] ${line#OK: }" ;;
		*) fail "[$c] ${line#NG: }" ;;
		esac
	done <"$TMP/$c.an"
done

# ---- 4. Loki: trace_id 로그가 1건 이상 있고 고유 토큰이 없다 ----
loki_raw() { # <trace_id> <out>
	curl -s --max-time 10 -G "http://127.0.0.1:$P_LOKI/loki/api/v1/query_range" \
		--data-urlencode "query={service_name=~\"lgtm-.+\"} | trace_id=\"$1\"" --data-urlencode "limit=500" \
		--data-urlencode "start=$(($(date +%s) - 900))000000000" --data-urlencode "end=$(($(date +%s) + 60))000000000" >"$2"
}
loki_n() { pyj "sum(len(r['values']) for r in d['data']['result'])" <"$1"; }
for c in $CASES; do
	tid="$(field "$c" "d['trace_id']")"
	n=0
	for i in $(seq 1 30); do
		loki_raw "$tid" "$TMP/$c.loki"
		n="$(loki_n "$TMP/$c.loki")"
		[ "${n:-0}" -ge 3 ] 2>/dev/null && break
		sleep 2
	done
	[ "${n:-0}" -ge 1 ] 2>/dev/null && pass "[$c] Loki: trace_id 로그 ${n}건 (trace-to-logs)" || fail "[$c] Loki: trace_id 로그 ${n:-0}건"
	if grep -qi "$(tok_of "$c")" "$TMP/$c.loki"; then fail "[$c] Loki 로그(본문·structured metadata)에 고유 토큰 있음"; else pass "[$c] Loki 로그에 고유 토큰 없음 (${n:-0}건 검사)"; fi
done

# ---- 5. Mimir ----
mimir() { local p="$1"; shift; curl -s --max-time 15 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/$p" "$@"; }
mseries() { # <selector> → series JSON, 최대 60s 폴링
	local out="" i
	for i in $(seq 1 30); do
		out="$(mimir series --data-urlencode "match[]=$1" --data-urlencode "start=$(($(date +%s) - 900))" --data-urlencode "end=$(($(date +%s) + 60))" | pyj "json.dumps(d['data'])")"
		[ -n "$out" ] && [ "$out" != "[]" ] && break
		sleep 2
	done
	printf '%s' "${out:-[]}"
}
le_list() { printf '%s' "$1" | pyj "sorted(set(s['le'] for s in d if 'le' in s))"; }
WANT_LE="['+Inf', '0.05', '0.1', '0.25', '0.5', '1', '10', '2', '20', '3', '4', '4.5', '5', '5.5']"
S="$(mseries 'lgtm_output_bytes_bucket')"
[ "$S" != "[]" ] && pass "Mimir: lgtm_output_bytes_bucket 존재 (저장 이름 확인)" || fail "Mimir: lgtm_output_bytes_bucket 없음 (저장된 lgtm_output* 이름: $(mimir label/__name__/values | pyj "[n for n in d['data'] if n.startswith('lgtm_output')]"))"
v="$(le_list "$S")"
printf '%s' "$v" | grep -q "'10240'" && pass "lgtm_output_bytes le 에 10240 포함: $v" || fail "lgtm_output_bytes le='$v' (10240 없음)"
for m in lgtm_execution_duration_seconds_bucket lgtm_stage_duration_seconds_bucket; do
	v="$(le_list "$(mseries "$m")")"
	[ "$v" = "$WANT_LE" ] && pass "$m le = PRD 8.2 bucket" || fail "$m le='$v' (기대 $WANT_LE)"
done
S="$(mseries '{__name__=~"lgtm_.*"}')"
v="$(printf '%s' "$S" | pyj "sorted(set(k for s in d for k in s) | set(s['__name__'] for s in d))")"
bad="$(printf '%s' "$S" | pyj "sorted(set(k for s in d for k in s if any(w in k.lower() for w in ('cid','sha','trace'))))")"
[ "$bad" = "[]" ] && pass "lgtm_* label 이름에 cid/sha/trace 없음 ($(printf '%s' "$S" | pyj "len(d)")개 series)" || fail "lgtm_* label 에 high-cardinality 의심 이름: $bad"
info "lgtm_* 이름·label 전체: $v"
ex="$(mimir query_exemplars --data-urlencode 'query=lgtm_execution_duration_seconds_bucket' --data-urlencode "start=$(($(date +%s) - 900))" --data-urlencode "end=$(($(date +%s) + 60))" |
	pyj "len([e for r in d['data'] for x in r['exemplars'] for e in [x] if len(e['labels'].get('trace_id',''))==32])")"
[ "${ex:-0}" -ge 1 ] 2>/dev/null && pass "exemplar 가 trace_id 를 반환 (${ex}건)" || fail "exemplar trace_id ${ex:-0}건"

# ---- 6. 단위 테스트 (VM 에 Go 설치 없이 images.txt 의 golang 이미지로) ----
GO_IMG="$(awk '$1=="build" && $2 ~ /^golang:/ {print $2; exit}' images.txt)"
if [ -n "$GO_IMG" ] && "$ROOT/scripts/with-docker.sh" docker run --rm -v "$ROOT/backend:/src" -w /src -e GOTOOLCHAIN=local -e CGO_ENABLED=1 "$GO_IMG" go test -count=1 ./internal/... >"$TMP/gotest.log" 2>&1; then
	pass "go test ./internal/... ($GO_IMG)"
else
	fail "go test ./internal/... 실패 (이미지='$GO_IMG')"; tail -20 "$TMP/gotest.log" >&2
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS (m5-01)"; exit 0; fi
echo "FAILED: ${fails}건 (m5-01)" >&2
exit 1
