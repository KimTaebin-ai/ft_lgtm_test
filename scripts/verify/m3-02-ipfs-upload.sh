#!/usr/bin/env bash
# F-M3-02 ipfs-upload 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# /api/execute 결과가 Kubo 에 main.rs / output.txt / status.json 디렉토리로 올라가고(pin), 같은 입력이면 같은 CID,
# Tempo ipfs.upload span 의 ipfs.cid, Kubo 5001 이 막히면 10초 timeout → 결과는 반환하고 cid/ipfs_url=null + span ERROR.
# 5001 차단은 kubo-ingress NetworkPolicy 를 임시로 바꾼다 (원본을 저장해 trap 에서 그 원본으로 복구한다. kubo.yaml 전체 재적용 안 함).
# 이 클러스터의 NetworkPolicy 는 연결을 거부(REJECT)해 빨리 실패하므로, 실제 10초 timeout 은 별도로 Kubo daemon 을 kill -STOP 해서 잰다
# (커널이 연결은 받지만 응답이 없는 상태). trap 에서 반드시 kill -CONT 한다.
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
IPFS_NS="ipfs"
HOST="lgtm.local"
GWHOST="ipfs.lgtm.local"
URL="http://$HOST/api/execute"
k() { kubectl --context "$CTX" "$@"; }
kx() { k -n "$IPFS_NS" exec kubo-0 -c kubo -- "$@"; }

# 다른 verify 와 겹치지 않는 port-forward 대역 (m2-04 = 24xxx)
P_MIMIR=26080
P_TEMPO=26200
TMP="$(mktemp -d)"
T_START="$(date +%s)"
MARK="m302-$(date +%s)-$$"
POLL_STEP=2
POLL_MAX=20 # 40s

. "$(dirname "${BASH_SOURCE[0]}")/lib-pf.sh"
PF_LOG_DIR="$TMP"

BLOCKED=0
STOPPED_PID=""
NODE="k3d-${CLUSTER_NAME:-lgtm}-server-0"
dk() { "$ROOT/scripts/lib/with-docker.sh" docker "$@"; }
ORIG_NP="$TMP/kubo-ingress.orig.json"
PROBE=probe-backend-m302

restore_np() {
	[ "$BLOCKED" = 1 ] || return 0
	k replace -f "$ORIG_NP" >/dev/null 2>&1 && BLOCKED=0
}
cont_kubo() {
	[ -n "$STOPPED_PID" ] || return 0
	dk exec "$NODE" kill -CONT "$STOPPED_PID" >/dev/null 2>&1 && STOPPED_PID=""
}
cleanup() {
	cont_kubo
	restore_np
	k -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
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
num_between() { python3 -I -c 'import sys; v,a,b=map(float,sys.argv[1:4]); sys.exit(0 if a<=v<=b else 1)' "$1" "$2" "$3" 2>/dev/null; }
field() { pyj "$2" <"$TMP/$1.json"; }
code_of() { cat "$TMP/$1.code" 2>/dev/null; }
mkreq() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$2" >"$TMP/$1.req"; } # mkreq <이름> <소스>
# send <이름> [curl 인자...] : .json .code .dt 를 남긴다
send() {
	local name="$1" t0 t1
	shift
	t0="$(now_s)"
	curl -s --max-time 60 --resolve "$HOST:80:127.0.0.1" -o "$TMP/$name.json" -w '%{http_code}' \
		-X POST -H 'Content-Type: application/json' "$@" --data-binary @"$TMP/$name.req" "$URL" >"$TMP/$name.code"
	t1="$(now_s)"
	elapsed "$t0" "$t1" >"$TMP/$name.dt"
}
gw() { curl -s --max-time 20 --resolve "$GWHOST:80:127.0.0.1" "$@"; }
pin_count() { kx ipfs pin ls --type=recursive 2>/dev/null | wc -l; }

# ---- 0. 전제 ----
ready=""
for i in $(seq 1 120); do
	lines="$(k -n "$NS" get pod -l app=backend -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
	if [ "$(printf '%s\n' "$lines" | grep -c .)" = "1" ] && [ "$lines" = "|true" ]; then ready="true"; break; fi
	sleep 1
done
[ "$ready" = "true" ] && pass "backend pod 1개, Ready" || fail "backend pod Ready 아님 (pods='${lines}')"
[ "$(k -n "$IPFS_NS" get pod kubo-0 -o jsonpath='{.status.containerStatuses[?(@.name=="kubo")].ready}' 2>/dev/null)" = "true" ] && pass "kubo-0 Ready" || fail "kubo-0 Ready 아님"
pf_forward observability mimir "$P_MIMIR:8080" || fail "port-forward (mimir) 실패"
pf_forward observability tempo "$P_TEMPO:3200" || fail "port-forward (tempo) 실패"

# ---- 1. 정상 코드: stdout + stderr ----
CODE_OK="fn main() { println!(\"m3-02 ok $MARK\"); eprintln!(\"err-line\"); }"
printf '%s' "$CODE_OK" >"$TMP/main.rs.sent"
mkreq ok "$CODE_OK"
send ok
[ "$(code_of ok)" = 200 ] && pass "정상 코드 → 200" || fail "정상 코드 HTTP '$(code_of ok)' body=$(head -c 200 "$TMP/ok.json")"
CID_OK="$(field ok "d['cid'] or ''")"
URL_OK="$(field ok "d['ipfs_url'] or ''")"
[ "$(field ok "d['status']")" = success ] && pass "status=success" || fail "status='$(field ok "d['status']")' ($(field ok "d.get('message','')"))"
[ -n "$CID_OK" ] && pass "cid 있음 ($CID_OK)" || fail "cid 없음 (응답: $(head -c 300 "$TMP/ok.json"))"
case "$CID_OK" in bafy*) pass "CIDv1 (bafy...)" ;; *) fail "CIDv1 아님: '$CID_OK'" ;; esac
[ "$URL_OK" = "http://$GWHOST/ipfs/$CID_OK/" ] && pass "ipfs_url = http://$GWHOST/ipfs/<cid>/" || fail "ipfs_url='$URL_OK'"
num_between "$(field ok "d['timings_ms']['ipfs_upload']")" 1 10000 && pass "timings_ms.ipfs_upload=$(field ok "d['timings_ms']['ipfs_upload']")ms" || fail "timings_ms.ipfs_upload='$(field ok "d['timings_ms']['ipfs_upload']")'"

# main.rs 바이트 동일
gw -o "$TMP/main.rs.got" "http://$GWHOST/ipfs/$CID_OK/main.rs"
cmp -s "$TMP/main.rs.sent" "$TMP/main.rs.got" && pass "gateway /main.rs 가 보낸 코드와 바이트 단위로 같음 ($(wc -c <"$TMP/main.rs.got")B)" || fail "main.rs 불일치 (받은 $(wc -c <"$TMP/main.rs.got")B, 보낸 $(wc -c <"$TMP/main.rs.sent")B)"
# output.txt 형식
printf -- '--- stdout ---\nm3-02 ok %s\n--- stderr ---\nerr-line\n' "$MARK" >"$TMP/output.txt.want"
gw -o "$TMP/output.txt.got" "http://$GWHOST/ipfs/$CID_OK/output.txt"
cmp -s "$TMP/output.txt.want" "$TMP/output.txt.got" && pass "output.txt = stdout/stderr 구분 형식" || fail "output.txt 불일치: $(head -c 200 "$TMP/output.txt.got" | cat -A | head -5)"
# status.json 정확히 (rustc 버전은 Dockerfile.compiler 태그와 같아야 함)
RUSTC_TAG="$(sed -n 's/^FROM rust:\([0-9.]*\)-.*/\1/p' backend/Dockerfile.compiler | head -1)"
printf '{\n  "status": "success",\n  "message": "",\n  "exit_code": 0,\n  "truncated": false,\n  "language": "rust",\n  "edition": "2021",\n  "rustc": "%s"\n}\n' "$RUSTC_TAG" >"$TMP/status.json.want"
gw -o "$TMP/status.json.got" "http://$GWHOST/ipfs/$CID_OK/status.json"
cmp -s "$TMP/status.json.want" "$TMP/status.json.got" && pass "status.json 내용·형식 일치 (rustc=$RUSTC_TAG, 요청마다 달라지는 값 없음)" || fail "status.json 불일치: $(cat "$TMP/status.json.got" | head -12)"
# 디렉토리 구성: 정확히 3개
ls_out="$(kx ipfs ls "$CID_OK" 2>/dev/null | awk '{print $NF}' | sort | tr '\n' ' ')"
[ "$ls_out" = "main.rs output.txt status.json " ] && pass "디렉토리에 파일 정확히 3개: $ls_out" || fail "디렉토리 구성 이상: '$ls_out'"
# FE 가 만드는 형식 (끝 슬래시 없음) → -L 최종 200 + 디렉토리 응답
r="$(curl -s -L --max-time 20 --resolve "$GWHOST:80:127.0.0.1" -o "$TMP/dir.html" -w '%{http_code} %{num_redirects} %{url_effective}' "http://$GWHOST/ipfs/$CID_OK")"
set -- $r
if [ "${1:-}" = 200 ] && grep -q 'main.rs' "$TMP/dir.html" && grep -q 'output.txt' "$TMP/dir.html" && grep -q 'status.json' "$TMP/dir.html"; then
	pass "FE 형식 http://$GWHOST/ipfs/<cid> (슬래시 없음) curl -L → 최종 200, 디렉토리 목록(3개 파일), redirect ${2:-?}회, 최종 URL ${3:-?}"
else
	fail "FE 형식 curl -L 결과: '$r' (디렉토리 목록 응답 아님: $(head -c 120 "$TMP/dir.html"))"
fi

# ---- 2. 실패 status 도 업로드 ----
status_json() { gw "http://$GWHOST/ipfs/$1/status.json"; } # <cid>
check_fail_case() { # <이름> <기대 status> <기대 exit_code 표기: null|숫자>
	local name="$1" want="$2" ec="$3" cid st
	cid="$(field "$name" "d['cid'] or ''")"
	st="$(field "$name" "d['status']")"
	[ "$st" = "$want" ] && pass "$name: status=$want" || fail "$name: status='$st' (기대 $want, message=$(field "$name" "d.get('message','')"))"
	[ -n "$cid" ] && pass "$name: cid 있음" || { fail "$name: cid 없음"; return; }
	status_json "$cid" >"$TMP/$name.status.json"
	[ "$(pyj "d['status']" <"$TMP/$name.status.json")" = "$want" ] && pass "$name: status.json status=$want" || fail "$name: status.json='$(head -c 200 "$TMP/$name.status.json")'"
	[ "$(pyj "repr(d['exit_code'])" <"$TMP/$name.status.json" | sed 's/^None$/null/')" = "$ec" ] && pass "$name: status.json exit_code=$ec" || fail "$name: status.json exit_code='$(pyj "repr(d['exit_code'])" <"$TMP/$name.status.json")' (기대 $ec)"
	CIDS+=("$cid")
}
CIDS=("$CID_OK")
mkreq ce "fn main() { let x: i32 = ; }"
send ce
check_fail_case ce compile_error null
gw "http://$GWHOST/ipfs/$(field ce "d['cid']")/output.txt" >"$TMP/ce.output.txt"
grep -q '^--- stderr ---$' "$TMP/ce.output.txt" && grep -qi 'error' "$TMP/ce.output.txt" && pass "compile_error: output.txt 의 stderr 섹션에 rustc 에러" || fail "compile_error output.txt: $(head -c 200 "$TMP/ce.output.txt")"

mkreq dl 'fn main() { let s = include_str!("/etc/passwd"); println!("{}", s); }'
send dl
check_fail_case dl compile_error null
grep -q 'root:' <(gw "http://$GWHOST/ipfs/$(field dl "d['cid']")/output.txt") && fail "deny-list 업로드 output.txt 에 /etc/passwd 내용 노출" || pass "deny-list compile_error: 업로드됐고 파일 내용 노출 없음"

mkreq to "fn main() { let _m = \"$MARK\"; loop {} }"
send to
check_fail_case to timeout -1

mkreq re 'fn main() { eprintln!("bye"); std::process::exit(3); }'
send re
check_fail_case re runtime_error 3

mkreq tr 'fn main() { let s = "x".repeat(20000); println!("{}", s); }'
send tr
[ "$(field tr "d['truncated']")" = True ] && pass "truncated 응답" || fail "truncated='$(field tr "d['truncated']")'"
gw "http://$GWHOST/ipfs/$(field tr "d['cid']")/output.txt" >"$TMP/tr.output.txt"
[ "$(tail -n1 "$TMP/tr.output.txt")" = "--- truncated: output exceeded 10240 bytes ---" ] && pass "truncated: output.txt 마지막 줄 표시" || fail "truncated output.txt 마지막 줄='$(tail -n1 "$TMP/tr.output.txt" | head -c 100)'"
gw "http://$GWHOST/ipfs/$(field tr "d['cid']")/status.json" | grep -q '"truncated": true' && pass "truncated: status.json truncated=true" || fail "truncated: status.json truncated 표시 없음"
CIDS+=("$(field tr "d['cid']")")

# ---- 3. pin ----
for c in "${CIDS[@]}"; do
	[ -n "$c" ] || continue
	kx ipfs pin ls --type=recursive "$c" >/dev/null 2>&1 && pass "pin ls --type=recursive $c" || fail "pin 안 됨: $c"
done

# ---- 4. 결정론: 같은 코드 → 같은 CID ----
send ok
CID_OK2="$(field ok "d['cid'] or ''")"
[ -n "$CID_OK2" ] && [ "$CID_OK2" = "$CID_OK" ] && pass "같은 코드 두 번 → 같은 CID ($CID_OK2)" || fail "같은 코드인데 CID 다름: '$CID_OK' vs '$CID_OK2'"
mkreq ok_b "fn main() { println!(\"m3-02 other $MARK\"); }"
send ok_b
[ -n "$(field ok_b "d['cid'] or ''")" ] && [ "$(field ok_b "d['cid']")" != "$CID_OK" ] && pass "다른 코드 → 다른 CID" || fail "다른 코드인데 CID 같거나 없음"

# ---- 5. 업로드하지 않는 응답: 400 / 413 ----
P0="$(pin_count)"
printf '{"language":"rust","code":""}' >"$TMP/bad.req"
send bad
big="// $(head -c 66000 /dev/zero | tr '\0' 'a')
fn main() {}"
mkreq big "$big"
send big
P1="$(pin_count)"
[ "$(code_of bad)" = 400 ] && [ "$(code_of big)" = 413 ] && pass "400 / 413 응답" || fail "400/413 코드: $(code_of bad)/$(code_of big)"
[ "$P0" = "$P1" ] && pass "400/413 은 업로드하지 않음 (pin 개수 $P0 → $P1)" || fail "400/413 후 pin 개수 변동 $P0 → $P1"

# ---- 6. Tempo: ipfs.upload span 의 ipfs.cid, root 의 ipfs.cid ----
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
            code=(s.get("status") or {}).get("code", 0)
            err = code in (2, "2", "STATUS_CODE_ERROR")
            out.append({"name": s["name"], "root": not s.get("parentSpanId"), "err": err, "attr": {a["key"]: val(a["value"]) for a in s.get("attributes", [])}})
print(json.dumps(out))'
# trace_summary <trace_id> <기대 span 이름 수> : 최대 60s 폴링 → JSON 요약 출력
trace_summary() {
	local out="" i
	for i in $(seq 1 30); do
		out="$(curl -s --max-time 10 "http://127.0.0.1:$P_TEMPO/api/traces/$1" | python3 -I -c "$SUMMARIZE" 2>/dev/null)"
		[ "$(printf '%s' "$out" | pyj "len([s for s in d if s['root']])")" = 1 ] && [ "$(printf '%s' "$out" | pyj "len([s for s in d if s['name']=='ipfs.upload'])")" = 1 ] && break
		sleep 2
	done
	printf '%s' "$out"
}
TID="$(field ok "d['trace_id']")"
SPANS="$(trace_summary "$TID")"
v="$(printf '%s' "$SPANS" | pyj "[s for s in d if s['name']=='ipfs.upload'][0]['attr'].get('ipfs.cid','')")"
[ -n "$v" ] && [ "$v" = "$CID_OK2" ] && pass "Tempo: ipfs.upload span ipfs.cid == 응답 cid" || fail "Tempo: ipfs.upload ipfs.cid='$v' (응답 cid '$CID_OK2')"
v="$(printf '%s' "$SPANS" | pyj "[s for s in d if s['root']][0]['attr'].get('ipfs.cid','')")"
[ -n "$v" ] && [ "$v" = "$CID_OK2" ] && pass "Tempo: root span ipfs.cid == 응답 cid" || fail "Tempo: root ipfs.cid='$v'"
[ "$(printf '%s' "$SPANS" | pyj "[s for s in d if s['name']=='ipfs.upload'][0]['err']")" = False ] && pass "Tempo: 성공 시 ipfs.upload span 은 ERROR 아님" || fail "Tempo: 성공인데 ipfs.upload span ERROR"

# ---- 7. Kubo 5001 차단 (kubo-ingress NetworkPolicy 임시 변경) ----
k -n "$IPFS_NS" get networkpolicy kubo-ingress -o json | python3 -I -c 'import json,sys
d=json.load(sys.stdin)
for key in ("resourceVersion","uid","creationTimestamp","generation","managedFields","selfLink"):
    d["metadata"].pop(key, None)
json.dump(d, sys.stdout)' >"$ORIG_NP" 2>/dev/null
[ -s "$ORIG_NP" ] && pass "원본 NetworkPolicy kubo-ingress 저장" || fail "원본 NetworkPolicy 저장 실패 (이후 차단 검사 중단)"
python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
d["spec"]["ingress"]=[r for r in d["spec"]["ingress"] if not any(p.get("port")==5001 for p in r.get("ports",[]))]
json.dump(d, sys.stdout)' "$ORIG_NP" >"$TMP/kubo-ingress.blocked.json"
SPEC_BEFORE="$(k -n "$IPFS_NS" get networkpolicy kubo-ingress -o jsonpath='{.spec}' 2>/dev/null)"

IMG="$(k -n "$IPFS_NS" get sts kubo -o jsonpath='{.spec.template.spec.containers[?(@.name=="kubo")].image}' 2>/dev/null)"
k -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true >/dev/null 2>&1
cat <<YAML | k -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $PROBE, labels: {app: backend}}
spec:
  automountServiceAccountToken: false
  containers:
    - name: probe
      image: $IMG
      imagePullPolicy: IfNotPresent
      command: ["sleep", "600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
YAML
k -n "$NS" wait --for=condition=Ready "pod/$PROBE" --timeout=90s >/dev/null 2>&1 || fail "probe pod(app=backend) Ready 아님"
conn() { # 5001 에 HTTP 응답을 받으면 성공 (app=backend 라벨 pod = backend 와 같은 정책 대상)
	k -n "$NS" exec "$PROBE" -- sh -c "wget -T 3 -S -O- --post-data= http://kubo-api.$IPFS_NS.svc.cluster.local:5001/api/v0/version 2>&1 | grep -q 'HTTP/'" >/dev/null 2>&1
}
# wait_state <ok|blocked> → 폴링 (상한 POLL_MAX×POLL_STEP 초), 실측 초를 WAITED 에 남긴다
wait_state() {
	local i t0; t0="$(now_s)"
	for i in $(seq 1 "$POLL_MAX"); do
		if conn; then [ "$1" = ok ] && { WAITED="$(elapsed "$t0" "$(now_s)")"; return 0; }; else [ "$1" = blocked ] && { WAITED="$(elapsed "$t0" "$(now_s)")"; return 0; }; fi
		sleep "$POLL_STEP"
	done
	WAITED="$(elapsed "$t0" "$(now_s)")"
	return 1
}
wait_state ok && pass "차단 전: backend 라벨 pod → kubo-api:5001 연결 성공 (poll 상한 $((POLL_MAX * POLL_STEP))s, 실측 ${WAITED}s)" || fail "차단 전부터 5001 연결 실패 (${WAITED}s)"

BLOCKED=1
if k replace -f "$TMP/kubo-ingress.blocked.json" >/dev/null 2>&1; then
	wait_state blocked && pass "5001 차단 확인: backend 라벨 pod → kubo-api:5001 연결 실패 (poll 상한 $((POLL_MAX * POLL_STEP))s, 실측 ${WAITED}s)" || fail "NetworkPolicy 변경 후에도 5001 연결됨 (${WAITED}s) — 이후 timeout 검사 무효"
else
	fail "차단용 NetworkPolicy replace 실패"
fi
mkreq blk "fn main() { println!(\"m3-02 blocked $MARK\"); }"
send blk
dt="$(cat "$TMP/blk.dt")"
[ "$(code_of blk)" = 200 ] && pass "Kubo 차단 중에도 200 (${dt}s)" || fail "Kubo 차단 중 HTTP '$(code_of blk)' (${dt}s) body=$(head -c 200 "$TMP/blk.json")"
num_between "$dt" 0 13 && pass "응답이 13초 안에 옴 (${dt}s)" || fail "응답 ${dt}s (기대 13초 이내)"
num_between "$dt" 9.5 13 && info "upload timeout(10s)에 걸림 = 패킷이 drop 되는 정책 (실측 ${dt}s)" || info "10초 전에 실패 (${dt}s) = 연결이 거부되는 정책"
[ "$(field blk "d['status']")" = success ] && [ "$(field blk "d['stdout'] == 'm3-02 blocked $MARK\\n'")" = True ] && pass "실행 결과 그대로 (status=success, stdout 일치)" || fail "실행 결과 변경됨: status='$(field blk "d['status']")' stdout='$(field blk "d['stdout']")'"
[ "$(field blk "d['cid'] is None")" = True ] && [ "$(field blk "d['ipfs_url'] is None")" = True ] && pass "cid=null, ipfs_url=null" || fail "cid/ipfs_url 이 null 아님: $(head -c 300 "$TMP/blk.json")"
[ "$(field blk "'ipfs_upload' in d['timings_ms']")" = True ] && info "timings_ms.ipfs_upload=$(field blk "d['timings_ms']['ipfs_upload']")ms"
BSP="$(trace_summary "$(field blk "d['trace_id']")")"
[ "$(printf '%s' "$BSP" | pyj "[s for s in d if s['name']=='ipfs.upload'][0]['err']")" = True ] && pass "Tempo: ipfs.upload span status ERROR" || fail "Tempo: ipfs.upload span ERROR 아님 ($(printf '%s' "$BSP" | head -c 300))"
[ "$(printf '%s' "$BSP" | pyj "[s for s in d if s['root']][0]['err']")" = False ] && pass "Tempo: root span 은 ERROR 아님 (업로드 실패는 부분 실패)" || fail "Tempo: root span 이 ERROR"
[ -z "$(printf '%s' "$BSP" | pyj "[s for s in d if s['name']=='ipfs.upload'][0]['attr'].get('ipfs.cid','')")" ] && pass "Tempo: 실패한 ipfs.upload span 에 ipfs.cid 없음" || fail "Tempo: 실패한데 ipfs.cid 있음"

# 복구 (저장한 원본으로) + 5001 접근 성공까지 poll
if k replace -f "$ORIG_NP" >/dev/null 2>&1; then
	BLOCKED=0
	pass "NetworkPolicy 를 저장한 원본으로 복구"
else
	fail "원본 NetworkPolicy 복구 실패 (trap 에서 재시도)"
fi
wait_state ok && pass "복구 후 5001 접근 성공 (poll 상한 $((POLL_MAX * POLL_STEP))s, 실측 ${WAITED}s)" || fail "복구 후에도 5001 접근 실패 (${WAITED}s)"
[ "$(k -n "$IPFS_NS" get networkpolicy kubo-ingress -o jsonpath='{.spec}' 2>/dev/null)" = "$SPEC_BEFORE" ] && pass "복구된 kubo-ingress spec 이 차단 전과 동일" || fail "복구된 kubo-ingress spec 이 차단 전과 다름"
send ok
[ "$(field ok "d['cid'] or ''")" = "$CID_OK" ] && pass "복구 후 요청은 다시 같은 CID 를 받음" || fail "복구 후 cid='$(field ok "d['cid']")' (기대 $CID_OK)"

# ---- 7b. 실제 10초 timeout: Kubo daemon 을 kill -STOP (연결은 받지만 응답 없음) ----
kubo_restarts() { k -n "$IPFS_NS" get pod kubo-0 -o jsonpath='{.status.containerStatuses[?(@.name=="kubo")].restartCount}' 2>/dev/null; }
RESTART_BEFORE="$(kubo_restarts)"
KPID="$(dk exec "$NODE" sh -c "ps -eo pid,args | awk '\$2==\"ipfs\" && \$3==\"daemon\" {print \$1; exit}'" 2>/dev/null)"
if [ -n "$KPID" ]; then
	pass "Kubo daemon PID=$KPID (node $NODE), restartCount 시작값=$RESTART_BEFORE"
	STOPPED_PID="$KPID"
	dk exec "$NODE" kill -STOP "$KPID" >/dev/null 2>&1 || fail "kill -STOP 실패"
	wait_state blocked && pass "Kubo 정지 확인: 5001 요청에 응답 없음 (poll 상한 $((POLL_MAX * POLL_STEP))s, 실측 ${WAITED}s)" || fail "Kubo 를 STOP 했는데 5001 이 응답함 (${WAITED}s) — 이후 timeout 검사 무효"
	mkreq stp "fn main() { println!(\"m3-02 stopped $MARK\"); }"
	send stp
	dt="$(cat "$TMP/stp.dt")"
	[ "$(code_of stp)" = 200 ] && pass "Kubo 정지 중에도 200 (${dt}s)" || fail "Kubo 정지 중 HTTP '$(code_of stp)' (${dt}s)"
	num_between "$dt" 10 13 && pass "응답이 10~13초 사이 (${dt}s) = 업로드 10초 timeout 에서 끊김" || fail "응답 ${dt}s (기대 10~13초)"
	[ "$(field stp "d['status']")" = success ] && [ "$(field stp "d['stdout'] == 'm3-02 stopped $MARK\\n'")" = True ] && pass "실행 결과 그대로 (status=success, stdout 일치)" || fail "실행 결과 변경됨: status='$(field stp "d['status']")'"
	[ "$(field stp "d['cid'] is None")" = True ] && [ "$(field stp "d['ipfs_url'] is None")" = True ] && pass "cid=null, ipfs_url=null" || fail "cid/ipfs_url 이 null 아님: $(head -c 300 "$TMP/stp.json")"
	info "timings_ms.ipfs_upload=$(field stp "d['timings_ms']['ipfs_upload']")ms (timeout 경로 실측)"
	SSP="$(trace_summary "$(field stp "d['trace_id']")")"
	[ "$(printf '%s' "$SSP" | pyj "[s for s in d if s['name']=='ipfs.upload'][0]['err']")" = True ] && pass "Tempo: ipfs.upload span status ERROR" || fail "Tempo: ipfs.upload span ERROR 아님 ($(printf '%s' "$SSP" | head -c 300))"
	[ "$(printf '%s' "$SSP" | pyj "[s for s in d if s['root']][0]['err']")" = False ] && pass "Tempo: root span 은 ERROR 아님" || fail "Tempo: root span 이 ERROR"
	# 복구: kill -CONT + 5001 응답 poll
	if dk exec "$NODE" kill -CONT "$KPID" >/dev/null 2>&1; then STOPPED_PID=""; pass "kill -CONT"; else fail "kill -CONT 실패 (trap 에서 재시도)"; fi
	wait_state ok && pass "kill -CONT 후 5001 응답 복구 (poll 상한 $((POLL_MAX * POLL_STEP))s, 실측 ${WAITED}s)" || fail "kill -CONT 후에도 5001 무응답 (${WAITED}s)"
	send ok
	[ "$(field ok "d['cid'] or ''")" = "$CID_OK" ] && pass "복구 후 요청은 다시 같은 CID 를 받음" || fail "복구 후 cid='$(field ok "d['cid']")'"
	RESTART_AFTER="$(kubo_restarts)"
	[ "$RESTART_BEFORE" = "$RESTART_AFTER" ] && pass "STOP/CONT 동안 Kubo 컨테이너 재시작 없음 (restartCount $RESTART_BEFORE → $RESTART_AFTER)" || fail "Kubo 컨테이너가 재시작됨 (restartCount $RESTART_BEFORE → $RESTART_AFTER) — 이 검사는 빼고 미확인으로 남길 것"
else
	fail "Kubo daemon PID 를 찾지 못함 (docker exec $NODE ps) — 10초 timeout 실측 불가"
fi

# ---- 8. Mimir: ipfs_upload stage count 증가 (성공 + timeout 업로드 포함) ----
mq() {
	curl -s --max-time 15 -G "http://127.0.0.1:$P_MIMIR/prometheus/api/v1/query" --data-urlencode "query=sum($1)" \
		| pyj "d['data']['result'][0]['value'][1]"
}
d=""
for i in $(seq 1 15); do
	w=$(( $(date +%s) - T_START + 15 ))
	d="$(mq "increase(lgtm_stage_duration_seconds_count{stage=\"ipfs_upload\"}[${w}s])")"
	[ -n "$d" ] && python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1])>0 else 1)' "$d" 2>/dev/null && break
	sleep 3
done
[ -n "$d" ] && python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1])>0 else 1)' "$d" 2>/dev/null && pass "lgtm_stage_duration_seconds_count{stage=ipfs_upload} increase = $d (> 0)" || fail "ipfs_upload stage count increase='$d'"
mx="$(mq "max_over_time(lgtm_stage_duration_seconds_sum{stage=\"ipfs_upload\"}[$(( $(date +%s) - T_START + 15 ))s])")"
info "ipfs_upload stage duration sum(참고)=${mx:-없음}"

# ---- 9. 코드 원문이 로그에 없음, rustc 버전 상수 일치 ----
n="$(k -n "$NS" logs deploy/backend --since=15m 2>&1 | grep -c "$MARK")"
[ "$n" = 0 ] && pass "backend 로그에 코드 원문(MARK) 없음" || fail "backend 로그에 코드 원문 ${n}줄"
CONST="$(sed -n 's/.*rustcVersion *= *"\([0-9.]*\)".*/\1/p' backend/internal/execute/files.go | head -1)"
[ -n "$CONST" ] && [ "$CONST" = "$RUSTC_TAG" ] && pass "rustcVersion 상수($CONST) == Dockerfile.compiler 태그($RUSTC_TAG)" || fail "rustcVersion 상수='$CONST' vs Dockerfile.compiler='$RUSTC_TAG'"

# ---- 10. 단위 테스트 (VM 에 Go 설치 없이 golang 이미지로 실행; cgo: 이미지에 gcc 포함) ----
if "$ROOT/scripts/lib/with-docker.sh" docker run --rm -v "$ROOT/backend:/src" -w /src -e GOTOOLCHAIN=local -e CGO_ENABLED=1 \
	golang:1.27.3-trixie go test -count=1 ./internal/... >"$TMP/gotest.log" 2>&1; then
	pass "go test ./internal/... 통과 (VM 의 docker golang:1.27.3-trixie 이미지)"
else
	fail "go test 실패: $(tail -20 "$TMP/gotest.log")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m3-02)"; exit 0; fi
echo "FAILED: ${fails}건 (m3-02)" >&2
exit 1
