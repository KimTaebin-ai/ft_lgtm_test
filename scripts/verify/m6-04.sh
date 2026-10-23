#!/usr/bin/env bash
# F-M6-04 stability 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make build deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# deployment 를 rollout restart 하는 동안 Ingress(Traefik) 경유로 1초 간격 요청을 보내 non-200 이 0건인지 본다 (PRD 12장 "배포 직후 504").
#   backend  : POST /api/execute 60건 (+ 재시작 때 처리 중이던 loop {} 1건이 끝까지 완료되는지)
#   compiler : 같은 요청 60건. backend→compiler keep-alive 가 끊기면 HTTP 200 + status=internal_error 로 나타나므로 본문 status 도 본다
#   frontend : GET / 30건
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
TMP="$(mktemp -d)"
BG_PIDS=()  # 종료 때 kill 할 모든 백그라운드 (요청 curl, 타임라인 루프, rollout status)
REQ_PIDS=() # wait 대상은 요청 curl 과 rollout status 뿐. 타임라인 루프는 끝나지 않으므로 wait 하면 멈춘다
cleanup() {
	local p
	for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }

python3 -I -c 'import json; print(json.dumps({"language":"rust","code":"fn main() { println!(\"hello\"); }"}))' >"$TMP/fast.req"
python3 -I -c 'import json; print(json.dumps({"language":"rust","code":"fn main() { let _x = 6004; loop {} }"}))' >"$TMP/slow.req"

# send_bg <이름> <post|get> [req 파일] : 백그라운드 curl. .code 에 "<HTTP 코드> <time_total> <시작 epoch>" 를 남긴다
send_bg() {
	local name="$1" kind="$2" t0
	t0="$(date +%s.%N)"
	if [ "$kind" = post ]; then
		(curl -s --max-time 60 --resolve "$HOST:80:127.0.0.1" -D "$TMP/$name.hdr" -o "$TMP/$name.json" -w "%{http_code} %{time_total} $t0" \
			-X POST -H 'Content-Type: application/json' --data-binary @"$3" "http://$HOST/api/execute" >"$TMP/$name.code" 2>/dev/null) &
	else
		(curl -s --max-time 60 --resolve "$HOST:80:127.0.0.1" -D "$TMP/$name.hdr" -o "$TMP/$name.json" -w "%{http_code} %{time_total} $t0" \
			"http://$HOST/" >"$TMP/$name.code" 2>/dev/null) &
	fi
	BG_PIDS+=("$!")
	REQ_PIDS+=("$!")
}
code_of() { cut -d' ' -f1 "$TMP/$1.code" 2>/dev/null; }

wait_ready() { # <deploy> : pod 1개, Ready, 종료 중 pod 없음
	local d="$1" i lines
	for i in $(seq 1 120); do
		lines="$(k -n "$NS" get pod -l "app=$d" -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)"
		[ "$(printf '%s\n' "$lines" | grep -c .)" = "1" ] && [ "$lines" = "|true" ] && return 0
		sleep 1
	done
	return 1
}

# phase <deploy> <post|get> <건수> <slow 요청 여부 0|1>
phase() {
	local d="$1" kind="$2" n="$3" slow="$4" i bad=0 c s tl_pid req_ok first_bad=""
	rm -f "$TMP"/r*.code "$TMP"/r*.json "$TMP"/r*.hdr "$TMP"/slow.code
	wait_ready "$d" && pass "[$d] 시작 전 pod 1개 Ready" || { fail "[$d] 시작 전 Ready 아님"; return; }
	# 원인 확인용 타임라인: pod 별 (deletionTimestamp 유무, ready), endpoint 주소. 실패할 때만 출력한다
	(while :; do
		printf '%s ' "$(date +%s.%N)"
		k -n "$NS" get pod -l "app=$d" -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.deletionTimestamp}:{.status.containerStatuses[0].ready} {end}' 2>/dev/null
		printf '| ep:'
		k -n "$NS" get endpointslice -l "kubernetes.io/service-name=$d" -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}:{.conditions.ready} {end}' 2>/dev/null
		echo
		sleep 0.2
	done >"$TMP/timeline.log") &
	tl_pid=$!
	BG_PIDS+=("$tl_pid")
	local t_restart=""
	for i in $(seq 1 "$n"); do
		[ "$i" = 3 ] && [ "$slow" = 1 ] && send_bg slow post "$TMP/slow.req"
		if [ "$i" = 5 ]; then
			t_restart="$(date +%s.%N)"
			k -n "$NS" rollout restart "deploy/$d" >/dev/null
			( k -n "$NS" rollout status "deploy/$d" --timeout=300s >"$TMP/rollout.log" 2>&1; echo $? >"$TMP/rollout.rc" ) &
			BG_PIDS+=("$!")
			REQ_PIDS+=("$!")
		fi
		send_bg "r$i" "$kind" "$TMP/fast.req"
		sleep 1
	done
	wait "${REQ_PIDS[@]}" 2>/dev/null
	kill "$tl_pid" 2>/dev/null
	wait "$tl_pid" 2>/dev/null
	[ "$(cat "$TMP/rollout.rc" 2>/dev/null)" = 0 ] && pass "[$d] rollout restart 완료" || fail "[$d] rollout status 실패: $(cat "$TMP/rollout.log" 2>/dev/null)"
	for i in $(seq 1 "$n"); do
		c="$(code_of "r$i")"
		if [ "$kind" = post ]; then s="$(pyj "d['status']" <"$TMP/r$i.json")"; req_ok=$([ "$c" = 200 ] && [ "$s" = success ] && echo 1 || echo 0)
		else s=""; req_ok=$([ "$c" = 200 ] && echo 1 || echo 0); fi
		if [ "$req_ok" != 1 ]; then
			bad=$((bad + 1))
			[ -z "$first_bad" ] && first_bad="$i"
			info "[$d] 요청 r$i: HTTP '$c' status='$s' $(cut -d' ' -f2- "$TMP/r$i.code") 본문: $(head -c 200 "$TMP/r$i.json")"
		fi
	done
	[ "$bad" = 0 ] && pass "[$d] rollout restart 중 ${n}건 모두 HTTP 200${s:+, status=success}" || fail "[$d] ${n}건 중 ${bad}건 실패 (기대 0). 첫 실패 r$first_bad"
	if [ "$slow" = 1 ]; then
		c="$(code_of slow)"; s="$(pyj "d['status']" <"$TMP/slow.json")"
		[ "$c" = 200 ] && [ "$s" = timeout ] && pass "[$d] 재시작 때 처리 중이던 loop {} 요청이 끝까지 완료 (HTTP 200, status=timeout)" \
			|| { fail "[$d] 처리 중이던 loop {} 요청: HTTP '$c' status='$s' ($(cut -d' ' -f2- "$TMP/slow.code"))"; }
	fi
	if [ "$bad" != 0 ] || { [ "$slow" = 1 ] && [ "$(code_of slow)" != 200 ]; }; then
		{
			echo "--- DIAG [$d] 재시작 시작 epoch $t_restart"
			echo "--- DIAG 타임라인 (epoch pod:deletionTimestamp:ready | endpoint:ready) 변화 줄만:"
			uniq -f1 "$TMP/timeline.log" | head -60
			echo "--- DIAG traefik 로그:"; k -n kube-system logs deploy/traefik --since=180s --tail=80 2>&1
			echo "--- DIAG pods:"; k -n "$NS" get pods -l "app=$d" -o wide 2>&1
			echo "--- DIAG events:"; k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -15
			[ -n "$first_bad" ] && { echo "--- DIAG r$first_bad 헤더:"; cat "$TMP/r$first_bad.hdr" 2>/dev/null; }
		} >&2
	fi
	BG_PIDS=()
	REQ_PIDS=()
	rm -f "$TMP/rollout.rc" "$TMP/rollout.log"
}

# 직전 스크립트의 요청이 남지 않도록 backend 부터 시작 전 Ready 를 확인한다 (phase 안에서 확인)
phase backend post 60 1
phase compiler post 60 0
phase frontend get 30 0

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m6-04)"; exit 0; fi
echo "FAILED: ${fails}건 (m6-04)" >&2
exit 1
