#!/usr/bin/env bash
# F-M2-04 limits-queue 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# 64KB → 413 (본문을 다 읽지 않음), 처리 2 + 대기 8, 동시 20개 → 429 정확히 10, lgtm_queue_rejected_total +10,
# stage="queue" series, 대기 중 클라이언트가 끊으면 자리 반환, 413/429/400 은 lgtm_executions_total 에 안 들어감.
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
URL="http://$HOST/api/execute"
k() { kubectl --context "$CTX" "$@"; }

P_MIMIR=24080
P_TEMPO=24200
P_BACKEND=24081
TMP="$(mktemp -d)"
T_START="$(date +%s)"

. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
PF_LOG_DIR="$TMP"
BG_PIDS=()
cleanup() {
	local p
	for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
	pf_stop
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }
now_s() { date +%s.%N; }
elapsed() { python3 -I -c 'import sys; print("%.2f" % (float(sys.argv[2])-float(sys.argv[1])))' "$1" "$2"; }
# num_between <값> <min> <max>
num_between() { python3 -I -c 'import sys; v,a,b=map(float,sys.argv[1:4]); sys.exit(0 if a<=v<=b else 1)' "$1" "$2" "$3" 2>/dev/null; }
field() { pyj "$2" <"$TMP/$1.json"; } # field <이름> <파이썬 식 (d=응답)>
status_of() { field "$1" "d['status']"; }
# send_bg 는 .code 에 "<HTTP 코드>\n<time_total>" 을 남긴다 (send 는 코드만 + .dt)
code_of() { head -n1 "$TMP/$1.code" 2>/dev/null; }
dt_of() { if [ -f "$TMP/$1.dt" ]; then cat "$TMP/$1.dt"; else sed -n 2p "$TMP/$1.code" 2>/dev/null; fi; }

mkreq() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$2" >"$TMP/$1.req"; } # mkreq <이름> <소스>

# diag_http <이름> : 기대한 HTTP 코드가 아닐 때(특히 504) 응답 본문·헤더·소요 시간·traefik·backend 로그를 stderr 로 남긴다
diag_http() {
	local name="$1"
	{
		echo "--- DIAG [$name] HTTP $(code_of "$name") 소요 $(dt_of "$name")s"
		echo "--- DIAG 응답 헤더:"; cat "$TMP/$name.hdr" 2>/dev/null
		echo "--- DIAG 응답 본문 (앞 300바이트):"; head -c 300 "$TMP/$name.json"; echo
		echo "--- DIAG backend pod (Terminating 포함):"; k -n "$NS" get pods -l app=backend -o wide 2>&1
		echo "--- DIAG traefik 로그:"; k -n kube-system logs deploy/traefik --since=120s --tail=40 2>&1
		echo "--- DIAG backend 로그:"; k -n "$NS" logs deploy/backend --tail=15 2>&1
	} >&2
}

# send <이름> [curl 추가 인자...] : $TMP/<이름>.req 를 POST 하고 .json .hdr .code .dt 를 남긴다 (foreground)
send() {
	local name="$1" t0 t1
	shift
	t0="$(now_s)"
	curl -s --max-time 90 --resolve "$HOST:80:127.0.0.1" -D "$TMP/$name.hdr" -o "$TMP/$name.json" -w '%{http_code}' \
		-X POST -H 'Content-Type: application/json' "$@" --data-binary @"$TMP/$name.req" "$URL" >"$TMP/$name.code"
	t1="$(now_s)"
	elapsed "$t0" "$t1" >"$TMP/$name.dt"
}
# send_bg <이름> : 백그라운드 curl. PID 를 LAST_PID 에 남긴다 (kill 하면 클라이언트가 끊긴다)
send_bg() {
	local name="$1"
	curl -s --max-time 90 --resolve "$HOST:80:127.0.0.1" -D "$TMP/$name.hdr" -o "$TMP/$name.json" -w '%{http_code}\n%{time_total}' \
		-X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$name.req" "$URL" >"$TMP/$name.code" 2>/dev/null &
	LAST_PID=$!
	BG_PIDS+=("$LAST_PID")
}

# Mimir instant query → 합계 (없으면 0)
mq() {
	curl -s --max-time 15 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/query" --data-urlencode "query=sum($1)" \
		| pyj "d['data']['result'][0]['value'][1]"
}
mval() { local v; v="$(mq "$1")"; echo "${v:-0}"; }
# mval_at <식> <epoch> : 그 시각의 instant query 합계 (없으면 0)
mval_at() {
	local v
	v="$(curl -s --max-time 15 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/query" --data-urlencode "query=sum($1)" --data-urlencode "time=$2" | pyj "d['data']['result'][0]['value'][1]")"
	echo "${v:-0}"
}
# wait_stable : lgtm_executions_total 합계와 lgtm_queue_rejected_total 합계가 10초 간격 두 번 같을 때까지 기다린다 (상한 60초).
# 직전 스크립트의 요청은 5초 reader 주기 + collector batch 때문에 늦게 Mimir 에 들어온다. 안정되기 전에 구간을 잡으면
# 그 요청이 이번 increase() 구간에 섞인다 (F-M5-01 전체 verify 에서 m2-03 직후 실행 시 12 ≠ 11).
# 안정된 시각(두 번째 읽기)을 STABLE_AT 에 남긴다. 안정되지 않고 상한에 닿으면 STABLE_OK=0.
wait_stable() {
	local prev="" cur i
	STABLE_OK=0
	for i in 1 2 3 4 5 6 7; do
		cur="$(mval lgtm_executions_total)/$(mval lgtm_queue_rejected_total)"
		STABLE_AT="$(date +%s)"
		[ "$cur" = "$prev" ] && { STABLE_OK=1; return 0; }
		prev="$cur"
		[ "$i" -lt 7 ] && sleep 10
	done
	return 1
}
# poll_increase <설명> <counter 이름> <기대 증가량> : 합계가 안정된 뒤 sum(increase(<counter>[기준 시각 이후 경과+5s])) 를 읽는다.
# 기준 시각 T_BASE 는 시작 전에 wait_stable 로 잡은 안정 시각이다. +5s 는 reader 주기 한 번분이고, 기준 시각 앞 10초는 변화가 없었으므로 직전 스크립트의 요청은 구간에 들어오지 않는다.
# raw 값의 차이(sum 끝값 - 시작값)는 rollout 으로 counter 가 리셋되면 이전 pod 값 때문에 틀린다 (F-M2-04 에서 -48 이 나온 방식). increase() 는 리셋을 보정한다
# increase() 는 구간 끝을 외삽하므로 정수로 반올림한다. 0 초기화(execute.InitMetrics)가 있어야 series 의 첫 증가분을 놓치지 않는다
poll_increase() {
	local what="$1" counter="$2" want="$3" i d="" w
	wait_stable || info "$what: 끝값이 60초 안에 안정되지 않음 (마지막 읽기 사용)"
	for i in 1 2 3; do
		w=$(( $(date +%s) - T_BASE + 5 ))
		# 정확한 증가량 = 지금 합계 - 기준 시각 합계. increase() 는 구간 가장자리로 외삽해서 정수 11 이 11.8 로 읽히고 12 로 반올림됐다 (F-M6-04 진단: timeout 10.71 + success 1.07).
		# 구간에 counter reset 이 있으면 raw 차이가 틀리므로 그때만 increase() 를 쓴다
		if [ "$(mval "resets(${counter}[${w}s])" | python3 -I -c 'import sys; print(int(float(sys.stdin.read() or 0)))')" = 0 ]; then
			d="$(python3 -I -c 'import sys; print(int(round(float(sys.argv[1]) - float(sys.argv[2]))))' "$(mval "$counter")" "$(mval_at "$counter" "$T_BASE")")"
		else
			d="$(mval "increase(${counter}[${w}s])" | python3 -I -c 'import sys; print(int(round(float(sys.stdin.read() or 0))))')"
		fi
		[ "$d" = "$want" ] && break
		sleep 3
	done
	if [ "$d" = "$want" ]; then
		pass "$what 증가량 = $want (increase, 안정 후)"
	else
		fail "$what increase() = '$d' (기대 $want)"
		# 진단: 어느 status 가 더 들어왔는지 (F-M6-04)
		w=$(( $(date +%s) - T_BASE + 5 ))
		info "DIAG ${counter} 구간 ${w}s status 별: $(curl -s --max-time 15 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/query" --data-urlencode "query=sum by (status) (increase(${counter}[${w}s]))" \
			| python3 -I -c 'import json,sys
try:
    print({r["metric"].get("status","-"): round(float(r["value"][1]),2) for r in json.load(sys.stdin)["data"]["result"]})
except Exception as e:
    print("파싱 실패", e)')"
	fi
}

# ---- 0. 전제 ----
ready=""
for i in $(seq 1 120); do
	lines="$(k -n "$NS" get pod -l app=backend -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
	if [ "$(printf '%s\n' "$lines" | grep -c .)" = "1" ] && [ "$lines" = "|true" ]; then ready="true"; break; fi
	sleep 1
done
[ "$ready" = "true" ] && pass "backend pod 1개, Ready" || fail "backend pod Ready 아님 (pods='${lines}')"
pf_forward observability mimir "$P_MIMIR:8080" || fail "port-forward (mimir) 실패"
pf_forward observability tempo "$P_TEMPO:3200" || fail "port-forward (tempo) 실패"
info "pod 의 0 초기화 series 가 export 되도록 8초 대기"
sleep 8
# 기준값: 직전 스크립트(m2-03 등)의 요청이 모두 Mimir 에 들어와 합계가 안정된 뒤에 시작한다
if wait_stable; then info "시작 기준 안정 (executions/rejected 합계 10초간 변화 없음)"; else info "시작 기준이 60초 안에 안정되지 않음 (마지막 읽기에서 시작)"; fi
T_BASE="$STABLE_AT"
# ---- 1. 65KB body → 413, 응답이 짧음 ----
mkreq big "// $(head -c 66000 /dev/zero | tr '\0' 'a')
fn main() { println!(\"hi\"); }"
sz="$(stat -c %s "$TMP/big.req")"
send big
c="$(code_of big)"
[ "$c" = "413" ] && pass "body ${sz}바이트 → 413" || { fail "body ${sz}바이트 → HTTP '$c' (기대 413)"; diag_http big; }
[ "$c" = "413" ] && num_between "$(dt_of big)" 0 1 && pass "413 응답 $(dt_of big)s (< 1s)" || fail "413 응답 $(dt_of big)s (기대 < 1s)"
[ "$(status_of big)" = "payload_too_large" ] && pass "413 본문 status=payload_too_large" || fail "413 본문 status='$(status_of big)' body=$(head -c 200 "$TMP/big.json")"

# ---- 2. 본문을 다 읽지 않음 ----
# (a) backend 에 직접: Content-Length 만 크고 본문은 보내지 않는다. 본문을 기다리면 응답이 오지 않는다
pf_forward "$NS" backend "$P_BACKEND:80" || fail "port-forward (backend) 실패"
r="$(python3 -I - "$P_BACKEND" <<'PY'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
t0 = time.time()
s.sendall(b"POST /api/execute HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 5000000\r\n\r\n")
try:
    line = s.recv(200).split(b"\r\n")[0].decode()
except Exception as e:
    line = "ERR %s" % e
print("%s|%.2f" % (line, time.time() - t0))
PY
)"
case "$r" in
"HTTP/1.1 413"*) num_between "${r##*|}" 0 2 && pass "backend 직접: Content-Length 5000000 (본문 없음) → 413, ${r##*|}s" || fail "backend 직접 413 이 느림: $r" ;;
*) fail "backend 직접: Content-Length 5000000 (본문 없음) → '$r' (기대 HTTP/1.1 413)" ;;
esac
# (b) Ingress 경유: 실제 5MB 본문
head -c 5000000 /dev/zero | tr '\0' 'a' >"$TMP/huge.req"
send huge
c="$(code_of huge)"
[ "$c" = "413" ] && num_between "$(dt_of huge)" 0 2 && pass "Ingress 경유 5MB body → 413, $(dt_of huge)s" || { fail "5MB body → HTTP '$c' $(dt_of huge)s"; diag_http huge; }

# ---- 3. 64KB 안쪽 정상 요청 → 413 아님 ----
mkreq ok "// $(head -c 60000 /dev/zero | tr '\0' 'a')
fn main() { println!(\"hello\"); }"
sz="$(stat -c %s "$TMP/ok.req")"
send ok
c="$(code_of ok)"
[ "$c" = "200" ] && [ "$(status_of ok)" = "success" ] && pass "body ${sz}바이트 → 200 success" || { fail "body ${sz}바이트 → HTTP '$c' status='$(status_of ok)'"; diag_http ok; }

# ---- 4. 400 (JSON 아님) ----
printf '{' >"$TMP/bad.req"
send bad
[ "$(code_of bad)" = "400" ] && pass "깨진 JSON → 400" || fail "깨진 JSON → HTTP '$(code_of bad)'"

# ---- 5. 동시 20개 (loop {}, 서로 다른 코드) → 429 정확히 10, 200 정확히 10 ----
for i in $(seq 1 20); do mkreq "b$i" "fn main() { let _x = $i; loop {} }"; done
T_BURST="$(now_s)"
for i in $(seq 1 20); do send_bg "b$i"; done
# 처리 중 gauge: 처리 2 가 Mimir 에서 보이는지 (export 5초 주기)
seen_active=""; seen_waiting=""
for i in $(seq 1 10); do
	sleep 2
	[ "$(mval lgtm_queue_active)" = "2" ] && seen_active=1
	w="$(mval lgtm_queue_waiting)"
	python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1])>0 else 1)' "$w" && seen_waiting=1
	[ -n "$seen_active" ] && [ -n "$seen_waiting" ] && break
done
[ -n "$seen_active" ] && pass "gauge lgtm_queue_active = 2 관측" || fail "gauge lgtm_queue_active = 2 를 못 봄"
[ -n "$seen_waiting" ] && pass "gauge lgtm_queue_waiting > 0 관측" || fail "gauge lgtm_queue_waiting > 0 를 못 봄"
wait "${BG_PIDS[@]}" 2>/dev/null
T_END="$(now_s)"
n429=0; n200=0; other=0
for i in $(seq 1 20); do
	case "$(code_of "b$i")" in
	429) n429=$((n429 + 1)) ;;
	200) n200=$((n200 + 1)) ;;
	*) other=$((other + 1)); diag_http "b$i" ;;
	esac
done
[ "$n429" = 10 ] && pass "동시 20개 → 429 정확히 10개" || fail "429 = $n429개 (기대 10), 200 = $n200, 기타 = $other"
[ "$n200" = 10 ] && [ "$other" = 0 ] && pass "나머지 10개는 HTTP 200 (대기했던 요청 504 없음), 전체 $(elapsed "$T_BURST" "$T_END")s" || fail "200 = $n200개 (기대 10), 기타 = $other"
bad=0
for i in $(seq 1 20); do
	if [ "$(code_of "b$i")" = 200 ]; then [ "$(status_of "b$i")" = "timeout" ] || bad=$((bad + 1)); fi
done
[ "$bad" = 0 ] && pass "200 응답 10개 모두 status=timeout (loop {})" || fail "200 응답 중 timeout 아닌 것 ${bad}개"
fast=0; first429=""
for i in $(seq 1 20); do
	if [ "$(code_of "b$i")" = 429 ]; then
		[ -z "$first429" ] && first429="b$i"
		num_between "$(dt_of "b$i")" 0 3 || fast=$((fast + 1))
		[ "$(status_of "b$i")" = "queue_full" ] || fast=$((fast + 1))
	fi
done
[ "$n429" -gt 0 ] && [ "$fast" = 0 ] && pass "429 는 모두 즉시(< 3s) 반환, status=queue_full" || fail "429 중 느리거나 status 가 다른 것 ${fast}건 (예: $(head -c 200 "$TMP/${first429:-b1}.json"))"

# ---- 6. Mimir: rejected +10, executions +11 (ok 1 + burst 10; 413/429/400 제외), stage="queue" +11 ----
poll_increase "lgtm_queue_rejected_total (429 burst)" lgtm_queue_rejected_total 10
# 기대 11 = 60KB 정상 요청 1 (success) + burst 중 처리된 10 (timeout). 제외: 413 (65KB, 5MB), 400 (깨진 JSON), 429 10건 — 실행이 시작되지 않음
poll_increase "lgtm_executions_total (60KB 정상 1 + burst 처리 10; 413/400/429 제외)" lgtm_executions_total 11
# stage="queue" 는 승인된 요청마다 기록된다 (대기 0 도). 같은 pod 에서 compile 도 승인된 요청마다 정확히 한 번이므로 count 가 같아야 한다
# (rollout 으로 counter 가 리셋돼도 성립하는 불변식이라 기준값 차이 대신 쓴다)
for i in $(seq 1 15); do
	qc="$(mval 'lgtm_stage_duration_seconds_count{stage="queue"}')"; cc="$(mval 'lgtm_stage_duration_seconds_count{stage="compile"}')"
	[ "$qc" = "$cc" ] && [ "$qc" != 0 ] && break
	sleep 3
done
[ "$qc" = "$cc" ] && [ "$qc" != 0 ] && pass "stage=\"queue\" count($qc) == stage=\"compile\" count($cc) (대기 0 도 기록)" || fail "stage=\"queue\" count='$qc' stage=\"compile\" count='$cc'"
nb="$(mval 'lgtm_stage_duration_seconds_bucket{stage="queue"}')"
python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1])>0 else 1)' "$nb" && pass 'stage="queue" histogram bucket series 존재' || fail 'stage="queue" bucket series 없음'
qs="$(mval 'lgtm_stage_duration_seconds_sum{stage="queue"}')"
info "stage queue 누적 합계 ${qs}s"
for i in 1 2 3 4 5 6; do
	a="$(mval lgtm_queue_active)"; w="$(mval lgtm_queue_waiting)"
	[ "$a" = 0 ] && [ "$w" = 0 ] && break
	sleep 3
done
[ "$a" = 0 ] && [ "$w" = 0 ] && pass "종료 후 gauge active=0 waiting=0" || fail "종료 후 gauge active=$a waiting=$w"

# ---- 7. Tempo: 429 root span queue.rejected, 200 root span queue.wait_ms ----
SUMMARIZE='import json,sys
d=json.load(sys.stdin)
rs=d.get("batches") or d.get("resourceSpans") or []
def val(v):
    for kk in ("intValue","boolValue","stringValue","doubleValue"):
        if kk in v: return v[kk]
    return None
out=[]
for b in rs:
    for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
        for s in ss.get("spans", []):
            out.append({"name": s["name"], "root": not s.get("parentSpanId"), "attr": {a["key"]: val(a["value"]) for a in s.get("attributes", [])}})
print(json.dumps(out))'
root_attrs() { # <trace_id> → root span 이 보일 때까지 최대 60s, root attr 출력
	local out="" i
	for i in $(seq 1 30); do
		out="$(curl -s --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$1" | python3 -I -c "$SUMMARIZE" 2>/dev/null)"
		[ -n "$(printf '%s' "$out" | pyj "[s for s in d if s['root']]")" ] && [ "$(printf '%s' "$out" | pyj "len([s for s in d if s['root']])")" = 1 ] && break
		sleep 2
	done
	printf '%s' "$out" | pyj "[s for s in d if s['root']][0]['attr']"
}
if [ -n "$first429" ]; then
	a="$(root_attrs "$(field "$first429" "d['trace_id']")")"
	printf '%s' "$a" | grep -q "'queue.rejected': True" && pass "429 root span: queue.rejected=true" || fail "429 root span attr: $a"
fi
first200=""
for i in $(seq 1 20); do [ "$(code_of "b$i")" = 200 ] && { first200="b$i"; break; }; done
if [ -n "$first200" ]; then
	a="$(root_attrs "$(field "$first200" "d['trace_id']")")"
	printf '%s' "$a" | grep -q "queue.wait_ms" && pass "처리된 요청 root span: queue.wait_ms 존재" || fail "200 root span attr: $a"
fi

# ---- 8. 대기 중 클라이언트 끊김 → 자리 반환 ----
# 처리 2 + 대기 8 을 채운 뒤: 새 요청은 429, 대기 1건을 끊으면 새 요청이 큐에 들어간다 (즉시 429 가 아님)
for i in $(seq 1 10) p1 p2; do mkreq "c$i" "fn main() { let _y = $i; loop {} }"; done
mkreq p1 "fn main() { let _p = 101; loop {} }"
mkreq p2 "fn main() { let _p = 102; loop {} }"
BG_PIDS=()
send_bg c1; send_bg c2
sleep 0.7
WPID=""
for i in 3 4 5 6 7 8 9 10; do send_bg "c$i"; [ "$i" = 3 ] && WPID="$LAST_PID"; done
sleep 0.7
send p1
[ "$(code_of p1)" = "429" ] && pass "처리 2 + 대기 8 이 찬 상태의 11번째 요청 → 429" || { fail "11번째 요청 HTTP '$(code_of p1)' (기대 429)"; diag_http p1; }
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
sleep 0.5
send_bg p2
P2PID="$LAST_PID"
sleep 1.2
if [ "$(code_of p1)" = "429" ] && kill -0 "$P2PID" 2>/dev/null && [ -z "$(code_of p2)" ]; then
	pass "대기 요청 하나가 끊긴 뒤 새 요청이 큐에 들어감 (429 아님, 자리 반환)"
else
	fail "끊긴 뒤 새 요청이 큐에 못 들어감 (HTTP '$(code_of p2)' body=$(head -c 200 "$TMP/p2.json"))"
fi
wait "${BG_PIDS[@]}" 2>/dev/null
[ "$(code_of p2)" = "200" ] && pass "큐에 들어갔던 요청은 504 없이 완료 (HTTP 200, status=$(status_of p2))" || { fail "p2 HTTP '$(code_of p2)'"; diag_http p2; }
n=0; for i in 1 2 4 5 6 7 8 9 10; do [ "$(code_of "c$i")" = 200 ] && n=$((n + 1)); done
[ "$n" = 9 ] && pass "끊기지 않은 처리/대기 9건 모두 HTTP 200" || fail "끊기지 않은 9건 중 200 = $n건"

# ---- 9. 부하 종료 후 15초 안에 gauge 가 0 으로 돌아온다 (Mimir) ----
T_LOAD_END="$(now_s)"
a=""; w=""
for i in $(seq 1 8); do
	a="$(mval lgtm_queue_active)"; w="$(mval lgtm_queue_waiting)"
	[ "$a" = 0 ] && [ "$w" = 0 ] && break
	sleep 2
done
el="$(elapsed "$T_LOAD_END" "$(now_s)")"
[ "$a" = 0 ] && [ "$w" = 0 ] && num_between "$el" 0 15 && pass "부하 종료 후 ${el}s 안에 lgtm_queue_active=0, lgtm_queue_waiting=0" || fail "부하 종료 후 ${el}s: active='$a' waiting='$w' (기대 15초 안에 0, 0)"

# ---- 10. 단위 테스트 (limiter, 413/429 핸들러; cgo: golang 이미지에 gcc 포함) ----
if "$ROOT/scripts/with-docker.sh" docker run --rm -v "$ROOT/backend:/src" -w /src -e GOTOOLCHAIN=local -e CGO_ENABLED=1 \
	golang:1.27.3-trixie go test -count=1 ./internal/... >"$TMP/gotest.log" 2>&1; then
	pass "go test ./internal/... (limiter, 413/429 핸들러 포함) 통과"
else
	fail "go test 실패: $(tail -20 "$TMP/gotest.log")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m2-04)"; exit 0; fi
echo "FAILED: ${fails}건 (m2-04)" >&2
exit 1
