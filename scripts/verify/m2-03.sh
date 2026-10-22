#!/usr/bin/env bash
# F-M2-03 wasmtime-exec 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# PRD 7.2 sandbox 5종(동시성 제외) + 추가 케이스 + 동시성(epoch 가 요청 간 간섭하지 않음) + Tempo TR-04 attribute.
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

P_TEMPO=25200
TMP="$(mktemp -d)"

. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
PF_LOG_DIR="$TMP"
cleanup() { pf_stop; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

lurl() { curl -s --max-time 60 --resolve "$HOST:80:127.0.0.1" "$@"; }
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

# diag_http <이름> <HTTP 코드> <시작 시각 epoch> : /api/execute 가 200 + JSON 이 아닐 때 원인 수집용 출력 (워밍업으로 덮지 않는다)
diag_http() {
	local name="$1" code="$2" since="$3" now
	now="$(date +%s)"
	{
		echo "--- DIAG [$name] HTTP ${code} 소요 $(cat "$TMP/$name.dt")s (요청 $(date -d "@$since" '+%T') ~ 응답 $(date '+%T'))"
		echo "--- DIAG 응답 헤더:"; cat "$TMP/$name.hdr" 2>/dev/null
		echo "--- DIAG 응답 본문 (앞 300바이트; Traefik 텍스트인지 backend JSON 인지 확인):"; head -c 300 "$TMP/$name.json"; echo
		echo "--- DIAG backend pod (Terminating 포함):"; k -n "$NS" get pods -l app=backend -o wide 2>&1
		echo "--- DIAG traefik 로그 (kube-system, 최근 $((now - since + 30))초):"
		k -n kube-system logs deploy/traefik --since="$((now - since + 30))s" --tail=60 2>&1
		echo "--- DIAG backend 로그 (최근):"; k -n "$NS" logs deploy/backend --tail=15 2>&1
	} >&2
}

# run <이름> <소스> : 응답 본문을 $TMP/<이름>.json, 헤더를 .hdr, 벽시계 소요(초)를 .dt 에 남긴다. 200 이 아니거나 JSON 이 아니면 diag_http
run() {
	local name="$1" t0 t1 code s0
	python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$2" >"$TMP/$name.req"
	s0="$(date +%s)"
	t0="$(now_s)"
	code="$(lurl -D "$TMP/$name.hdr" -o "$TMP/$name.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$name.req" "http://$HOST/api/execute")"
	t1="$(now_s)"
	elapsed "$t0" "$t1" >"$TMP/$name.dt"
	if [ "$code" != "200" ] || [ -z "$(pyj "d['status']" <"$TMP/$name.json")" ]; then diag_http "$name" "$code" "$s0"; fi
}
field() { pyj "$2" <"$TMP/$1.json"; } # field <이름> <파이썬 식 (d=응답)>
status_of() { field "$1" "d['status']"; }
dt_of() { cat "$TMP/$1.dt"; }

# ---- 소스 ----
SRC_LOOP='fn main() { loop {} }'
SRC_MEM='fn main() { let v = vec![0u8; 100_000_000]; println!("{}", v[5]); }'
SRC_FS='fn main() { let s = std::fs::read("/etc/passwd").unwrap(); println!("{}", String::from_utf8_lossy(&s)); }'
SRC_NET='fn main() { let s = std::net::TcpStream::connect("1.1.1.1:80").unwrap(); println!("{:?}", s); }'
SRC_BIG='fn main() { let line = "x".repeat(1023) + "\n"; for _ in 0..1024 { print!("{}", line); } }'
SRC_LOOPP='fn main() { loop { println!("x"); } }'
SRC_ENV='fn main() { println!("env={} args={}", std::env::vars().count(), std::env::args().count()); }'
SRC_HELLO='fn main() { println!("hello"); }'
SRC_EXIT='fn main() { println!("bye"); std::process::exit(3); }'
SRC_PANIC='fn main() { println!("before"); panic!("boom"); }'
SRC_STDERR='fn main() { println!("out"); eprintln!("err"); }'
# 10kB 이상 stdout 으로 채운 뒤 OOM → alloc 실패 메시지가 truncation 으로 사라져도 memory_limit 이어야 한다
SRC_FILL_OOM='fn main() { let line = "y".repeat(1023) + "\n"; for _ in 0..20 { print!("{}", line); } let v = vec![1u8; 100_000_000]; println!("{}", v[5]); }'
# 초기 메모리(.bss 20MB)가 limit 10MB 를 넘어 instantiate 가 실패하는 모듈
SRC_BSS='static mut BUF: [u8; 20_000_000] = [0; 20_000_000];
fn main() { unsafe { let p = std::ptr::addr_of_mut!(BUF) as *mut u8; p.write_volatile(1); println!("{}", p.read_volatile()); } }'
EXAMPLE_SRC="$(python3 -I -c 'import re,sys; s=open(sys.argv[1]).read(); print(re.search(r"EXAMPLE_CODE = `(.*?)`", s, re.S).group(1))' frontend/src/example.ts)"

# ---- 0. 전제: backend 가 Ready, 쓸 수 있는 디스크 없음 ----
# rollout 직후에는 종료 중인 이전 pod 가 남아 있을 수 있다: 종료 중이 아닌 pod 가 정확히 하나이고 Ready 일 때까지 기다린다 (최대 120초)
ready=""
for i in $(seq 1 120); do
	lines="$(k -n "$NS" get pod -l app=backend -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
	if [ "$(printf '%s\n' "$lines" | grep -c .)" = "1" ] && [ "$lines" = "|true" ]; then ready="true"; break; fi
	sleep 1
done
[ "$ready" = "true" ] && pass "backend pod 1개, Ready" || fail "backend pod Ready 아님 (pods='${lines}')"
rofs="$(k -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null)"
vols="$(k -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.volumes}' 2>/dev/null)"
[ "$rofs" = "true" ] && [ -z "$vols" ] && pass "backend: readOnlyRootFilesystem=true, volume 없음 (출력이 디스크에 쓰일 곳이 없음)" || fail "backend rootfs/volumes (readOnlyRootFilesystem='${rofs}' volumes='${vols}')"
BPOD="$(k -n "$NS" get pod -l app=backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
RESTART0="$(k -n "$NS" get pod "$BPOD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
MEMLIM_BYTES="$(k -n "$NS" get pod "$BPOD" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
info "backend pod=$BPOD restart=$RESTART0 memory limit=$MEMLIM_BYTES"

# ---- 1. loop {} → timeout, 5~7초 ----
run loop "$SRC_LOOP"
[ "$(status_of loop)" = "timeout" ] && pass "loop {} → timeout" || fail "loop {} status='$(status_of loop)' body=$(head -c 300 "$TMP/loop.json")"
v="$(field loop "d['timings_ms']['execute']/1000")"
num_between "${v:-0}" 4.9 7 && pass "loop {} execute 소요 ${v}s (4.9~7s), 전체 $(dt_of loop)s" || fail "loop {} execute 소요 '${v}'s (기대 4.9~7s)"

# ---- 2. 메모리 100MB → memory_limit ----
run mem "$SRC_MEM"
[ "$(status_of mem)" = "memory_limit" ] && pass "vec![0u8; 100_000_000] → memory_limit" || fail "mem status='$(status_of mem)' body=$(head -c 300 "$TMP/mem.json")"

# ---- 3. 파일 읽기 → 실패, 응답 어디에도 root:x:0:0 없음 ----
run fs "$SRC_FS"
s="$(status_of fs)"
[ "$s" != "success" ] && [ -n "$s" ] && pass "std::fs::read(/etc/passwd) → $s (success 아님)" || fail "fs status='${s}'"
grep -q 'root:x:0:0' "$TMP/fs.json" && fail "fs 응답에 root:x:0:0 포함" || pass "fs 응답 어디에도 root:x:0:0 없음"

# ---- 4. TcpStream::connect → 실패 ----
run net "$SRC_NET"
s="$(status_of net)"
[ "$s" != "success" ] && [ -n "$s" ] && pass "TcpStream::connect → $s (success 아님)" || fail "net status='${s}'"

# ---- 5. 1MB 출력 → truncated, stdout+stderr ≤ 10240바이트 ----
run big "$SRC_BIG"
[ "$(status_of big)" = "success" ] && pass "1MB 출력 → success" || fail "big status='$(status_of big)'"
[ "$(field big "d['truncated']")" = "True" ] && pass "1MB 출력 → truncated=true" || fail "big truncated='$(field big "d['truncated']")'"
n="$(field big "len(d['stdout'].encode())+len(d['stderr'].encode())")"
[ -n "$n" ] && [ "$n" -le 10240 ] 2>/dev/null && pass "stdout+stderr = ${n}바이트 (≤ 10240)" || fail "stdout+stderr='${n}'바이트"

# ---- 6. loop { println!("x") } → timeout + truncated, 디스크·메모리가 제한 안 ----
run loopp "$SRC_LOOPP"
[ "$(status_of loopp)" = "timeout" ] && pass "loop { println } → timeout" || fail "loopp status='$(status_of loopp)'"
[ "$(field loopp "d['truncated']")" = "True" ] && pass "loop { println } → truncated=true" || fail "loopp truncated='$(field loopp "d['truncated']")'"
n="$(field loopp "len(d['stdout'].encode())+len(d['stderr'].encode())")"
[ -n "$n" ] && [ "$n" -le 10240 ] 2>/dev/null && pass "loop { println } 출력 ${n}바이트 (≤ 10240)" || fail "loopp 출력='${n}'바이트"
RESTART1="$(k -n "$NS" get pod "$BPOD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
oom="$(k -n "$NS" get pod "$BPOD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)"
[ "$RESTART1" = "$RESTART0" ] && [ "$oom" != "OOMKilled" ] && pass "위 실행 동안 backend 재시작 없음 (restart=$RESTART1, OOMKilled 아님)" || fail "backend 재시작/OOM (restart $RESTART0 → $RESTART1, reason='${oom}')"
peak="$(k -n "$NS" exec "$BPOD" -- cat /sys/fs/cgroup/memory.peak 2>/dev/null)"
lim="$(k -n "$NS" exec "$BPOD" -- cat /sys/fs/cgroup/memory.max 2>/dev/null)"
if [ -n "$peak" ] && [ -n "$lim" ] && [ "$lim" != "max" ]; then
	[ "$peak" -lt "$lim" ] && pass "backend cgroup memory.peak=${peak} < memory.max=${lim}" || fail "backend memory.peak=${peak} ≥ memory.max=${lim}"
else
	fail "backend cgroup memory.peak/max 를 읽지 못함 (peak='${peak}' max='${lim}')"
fi
left="$(k -n "$NS" exec "$BPOD" -- sh -c 'find /tmp /var/tmp -mindepth 1 2>/dev/null' 2>&1)"
[ -z "$left" ] && pass "backend /tmp, /var/tmp 비어 있음 (임시 파일 0개)" || fail "backend 임시 파일 잔여: $left"

# ---- 7. env / args ----
run env "$SRC_ENV"
[ "$(field env "d['stdout'].strip()")" = "env=0 args=1" ] && pass "환경변수 0개, args 1개 (env=0 args=1)" || fail "env 출력='$(field env "d['stdout']")' status=$(status_of env)"

# ---- 8. 정상 예제 → success, 기대 출력 ----
run hello "$SRC_HELLO"
[ "$(status_of hello)" = "success" ] && [ "$(field hello "d['stdout']")" = "hello" ] && pass "hello → success, stdout=hello" || fail "hello status='$(status_of hello)' stdout='$(field hello "d['stdout']")'"
[ "$(field hello "d['truncated']")" = "False" ] && pass "hello truncated=false" || fail "hello truncated='$(field hello "d['truncated']")'"
run example "$EXAMPLE_SRC"
[ "$(status_of example)" = "success" ] && pass "frontend 기본 예제 → success" || fail "example status='$(status_of example)' body=$(head -c 300 "$TMP/example.json")"
v="$(field example "'y' if 'total area = 19.85' in d['stdout'] and 'even squares = [4, 16, 36, 64, 100]' in d['stdout'] else ''")"
[ "$v" = "y" ] && pass "예제 출력: total area = 19.85, even squares = [4, 16, 36, 64, 100]" || fail "예제 stdout='$(field example "d['stdout']")'"
run stderrcase "$SRC_STDERR"
v="$(field stderrcase "d['stdout']+'|'+d['stderr']")"
[ "$v" = $'out\n|err' ] || [ "$v" = $'out\n|err\n' ] && pass "stdout/stderr 분리 (out / err)" || fail "stdout|stderr='${v}'"

# ---- 9. status 매핑: 비정상 종료 / panic ----
run exit3 "$SRC_EXIT"
[ "$(status_of exit3)" = "runtime_error" ] && pass "process::exit(3) → runtime_error" || fail "exit3 status='$(status_of exit3)'"
[ "$(field exit3 "d['stdout'].strip()")" = "bye" ] && pass "exit(3) 전 출력 보존" || fail "exit3 stdout='$(field exit3 "d['stdout']")'"
run panic "$SRC_PANIC"
[ "$(status_of panic)" = "runtime_error" ] && pass "panic! → runtime_error" || fail "panic status='$(status_of panic)'"
v="$(field panic "'y' if 'boom' in d['stderr'] else ''")"
[ "$v" = "y" ] && pass "panic 메시지가 stderr 에 있음" || fail "panic stderr='$(field panic "d['stderr']")'"

# ---- 10. 10kB 출력 후 OOM → memory_limit (alloc 메시지가 truncation 으로 사라져도) ----
run filloom "$SRC_FILL_OOM"
[ "$(status_of filloom)" = "memory_limit" ] && pass "10kB 출력 후 OOM → memory_limit" || fail "filloom status='$(status_of filloom)'"
[ "$(field filloom "d['truncated']")" = "True" ] && pass "10kB 출력 후 OOM → truncated=true" || fail "filloom truncated='$(field filloom "d['truncated']")'"
v="$(field filloom "'y' if 'memory allocation' in d['stderr'] or 'memory allocation' in d['stdout'] else ''")"
[ -z "$v" ] && pass "분류 전용 stderr tail 은 응답에 포함되지 않음" || fail "응답에 alloc 메시지가 노출됨"

# ---- 11. 초기 메모리 > 10MB → instantiate 실패도 memory_limit ----
run bss "$SRC_BSS"
[ "$(status_of bss)" = "memory_limit" ] && pass "초기 메모리 20MB 모듈 → memory_limit" || fail "bss status='$(status_of bss)' body=$(head -c 300 "$TMP/bss.json")"

# ---- 12. 동시성: loop {} 실행 중 hello 는 success, loop 만 timeout ----
( run cloop "$SRC_LOOP"; now_s >"$TMP/cloop.end" ) &
LPID=$!
sleep 3
run chello1 "$SRC_HELLO"
now_s >"$TMP/chello1.end"
run chello2 "$SRC_HELLO"
wait "$LPID"
[ "$(status_of chello1)" = "success" ] && [ "$(status_of chello2)" = "success" ] && pass "동시 실행 중 hello 2건 → success" || fail "동시 hello status='$(status_of chello1)','$(status_of chello2)'"
[ "$(status_of cloop)" = "timeout" ] && pass "동시 실행에서도 loop {} → timeout" || fail "동시 loop status='$(status_of cloop)'"
lend="$(cat "$TMP/cloop.end" 2>/dev/null)"; hend="$(cat "$TMP/chello1.end" 2>/dev/null)"
python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' "${hend:-1}" "${lend:-0}" 2>/dev/null \
	&& pass "hello 가 loop 종료 전에 끝남 (실제로 겹쳐 실행됨)" || fail "hello 종료(${hend})가 loop 종료(${lend}) 이후 — 겹치지 않음"
v="$(field chello1 "d['timings_ms']['execute']")"
[ -n "$v" ] && [ "$v" -lt 2000 ] 2>/dev/null && pass "동시 hello execute ${v}ms (< 2000, epoch 간섭 없음)" || fail "동시 hello execute='${v}'ms"

# ---- 13. Tempo: TR-04 attribute, 실패 시 execute / root span ERROR ----
pf_forward observability tempo "$P_TEMPO:3200" || fail "port-forward (tempo) 실패"
SUMMARIZE='import base64,json,sys
d=json.load(sys.stdin)
rs=d.get("batches") or d.get("resourceSpans") or []
out=[]
def val(v):
    for kk in ("intValue","boolValue","stringValue","doubleValue"):
        if kk in v: return v[kk]
    return None
for b in rs:
    for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
        for s in ss.get("spans", []):
            code=(s.get("status") or {}).get("code", 0)
            at={a["key"]: val(a["value"]) for a in s.get("attributes", [])}
            out.append({"name": s["name"], "root": not s.get("parentSpanId"), "error": code in (2,"2","STATUS_CODE_ERROR"), "attr": at})
print(json.dumps(out))'
tempo_spans() { # <trace_id> → execute span 이 보일 때까지 최대 60s
	local tid="$1" out="" i
	for i in $(seq 1 30); do
		out="$(curl -s --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$tid" | python3 -I -c "$SUMMARIZE" 2>/dev/null)"
		[ "$(printf '%s' "$out" | pyj "len([s for s in d if s['name']=='execute'])")" = "1" ] && break
		sleep 2
	done
	printf '%s' "$out"
}
# attr_check <케이스 이름> <exit_code 기대 | -> <timed_out> <truncated> <memory_limited> <execute ERROR 여부 True|False>
attr_check() {
	local name="$1" ec="$2" to="$3" tr="$4" ml="$5" err="$6" tid sp
	tid="$(field "$name" "d['trace_id']")"
	sp="$(tempo_spans "$tid")"
	local ex="[s for s in d if s['name']=='execute'][0]['attr']"
	local got
	got="$(printf '%s' "$sp" | pyj "(lambda a: (a.get('exec.exit_code') is not None, a.get('exec.timed_out'), a.get('exec.output_truncated'), a.get('exec.memory_limited')))($ex)")"
	[ "$got" = "(True, $to, $tr, $ml)" ] && pass "[$name] TR-04 attribute exit_code 존재, timed_out=$to output_truncated=$tr memory_limited=$ml" || fail "[$name] TR-04 attribute 불일치: $got (기대 (True, $to, $tr, $ml))"
	if [ "$ec" != "-" ]; then
		got="$(printf '%s' "$sp" | pyj "$ex.get('exec.exit_code')")"
		[ "$got" = "$ec" ] && pass "[$name] exec.exit_code=$ec" || fail "[$name] exec.exit_code='${got}' (기대 $ec)"
	fi
	got="$(printf '%s' "$sp" | pyj "([s for s in d if s['name']=='execute'][0]['error'], [s for s in d if s['root']][0]['error'])")"
	[ "$got" = "($err, $err)" ] && pass "[$name] execute / root span error=$err" || fail "[$name] execute/root error='${got}' (기대 ($err, $err))"
}
attr_check hello 0 False False False False
attr_check exit3 3 False False False True
attr_check loop - True False False True
attr_check loopp - True True False True
attr_check mem - False False True True
attr_check big 0 False True False False

# ---- 14. 단위 테스트 (cgo: golang 이미지에 gcc 포함) ----
if "$ROOT/scripts/with-docker.sh" docker run --rm -v "$ROOT/backend:/src" -w /src -e GOTOOLCHAIN=local -e CGO_ENABLED=1 \
	golang:1.27.3-trixie go test -count=1 ./internal/... >"$TMP/gotest.log" 2>&1; then
	pass "go test ./internal/... (wasmtime 실행기 단위 테스트 포함) 통과"
else
	fail "go test 실패: $(tail -20 "$TMP/gotest.log")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m2-03)"; exit 0; fi
echo "FAILED: ${fails}건 (m2-03)" >&2
exit 1
