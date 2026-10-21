#!/usr/bin/env bash
# LGTM 트래픽 생성기: 정상 / __slow__ / __fail_compile__ 요청을 섞어 POST /api/execute 로 보낸다.
# verify(m1-04), dashboard 개발(M5), 디펜스 시연에서 재사용한다.
#
# 단발 모드 (기본): 정해진 건수를 보내고 끝난다. verify 는 이 모드만 쓴다.
#   load.sh [-n N] [--ok A] [--slow B] [--fail C]
#   --ok/--slow/--fail 중 하나라도 주면 그 건수를 그대로 쓰고 -n 은 무시한다 (안 준 종류는 0).
#   아무것도 안 주면 N(기본 20)을 정상 : slow : fail = 5 : 1 : 1 에 가깝게 나눈다.
# 지속 모드: 정해진 시간 동안 간격을 두고 가중 랜덤(정상 70% / slow 15% / fail 15%)으로 보낸다.
#   load.sh -d <초> [--interval <초>]      (--interval 기본 1, 소수 허용)
#
# stdout: 요청마다 한 줄 "<kind> <status> <trace_id>"  (kind = ok|slow|fail, 실패 시 status=http_<code>)
# stderr: 요약
# 환경변수: BASE_URL (기본 http://lgtm.local), RESOLVE (기본 lgtm.local:80:127.0.0.1, 빈 값이면 --resolve 안 씀)
set -u

BASE_URL="${BASE_URL:-http://lgtm.local}"
RESOLVE="${RESOLVE-lgtm.local:80:127.0.0.1}"
N=20; OK=""; SLOW=""; FAIL=""; DUR=""; INTERVAL=1

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
num() { case "$2" in '' | *[!0-9.]* ) echo "ERROR: $1 는 숫자여야 합니다 ('$2')" >&2; exit 2 ;; esac; }
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case "$1" in
		-n) num "$1" "$2"; N="$2" ;;
		--ok) num "$1" "$2"; OK="$2" ;;
		--slow) num "$1" "$2"; SLOW="$2" ;;
		--fail) num "$1" "$2"; FAIL="$2" ;;
		-d) num "$1" "$2"; DUR="$2" ;;
		--interval) num "$1" "$2"; INTERVAL="$2" ;;
		*) usage ;;
	esac
	shift 2
done

declare -A CODE=(
	[ok]='fn main() { println!(\"hello\"); }'
	[slow]='fn main() { /* __slow__ */ }'
	[fail]='fn main() { /* __fail_compile__ */ }'
)
declare -A SENT=([ok]=0 [slow]=0 [fail]=0) BAD=([ok]=0 [slow]=0 [fail]=0)

# send <kind> : 한 줄 출력. 응답에서 status / trace_id 를 뽑는다 (JSON 필드는 항상 존재, 6.2)
send() {
	local kind="$1" out http status tid args=()
	[ -n "$RESOLVE" ] && args=(--resolve "$RESOLVE")
	out="$(curl -s --max-time 30 "${args[@]}" -w '\n%{http_code}' -X POST \
		-H 'Content-Type: application/json' \
		--data "{\"language\":\"rust\",\"code\":\"${CODE[$kind]}\"}" "$BASE_URL/api/execute")"
	http="${out##*$'\n'}"
	status="$(printf '%s' "$out" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
	tid="$(printf '%s' "$out" | grep -o '"trace_id":"[0-9a-f]\{32\}"' | head -1 | cut -d'"' -f4)"
	SENT[$kind]=$((SENT[$kind] + 1))
	if [ "$http" != "200" ] || [ -z "$tid" ]; then
		BAD[$kind]=$((BAD[$kind] + 1))
		printf '%s http_%s -\n' "$kind" "$http"
		return
	fi
	printf '%s %s %s\n' "$kind" "$status" "$tid"
}

if [ -n "$DUR" ]; then
	end=$((SECONDS + ${DUR%.*}))
	while [ "$SECONDS" -lt "$end" ]; do
		r=$((RANDOM % 100))
		if [ "$r" -lt 70 ]; then send ok; elif [ "$r" -lt 85 ]; then send slow; else send fail; fi
		sleep "$INTERVAL"
	done
else
	if [ -z "$OK$SLOW$FAIL" ]; then
		SLOW=$((N / 7)); FAIL=$((N / 7)); OK=$((N - SLOW - FAIL))
	fi
	OK="${OK:-0}"; SLOW="${SLOW:-0}"; FAIL="${FAIL:-0}"
	# 종류별로 몰리지 않게 라운드로빈으로 섞는다
	todo_ok=$OK; todo_slow=$SLOW; todo_fail=$FAIL
	while [ $((todo_ok + todo_slow + todo_fail)) -gt 0 ]; do
		if [ "$todo_ok" -gt 0 ]; then send ok; todo_ok=$((todo_ok - 1)); fi
		if [ "$todo_slow" -gt 0 ]; then send slow; todo_slow=$((todo_slow - 1)); fi
		if [ "$todo_fail" -gt 0 ]; then send fail; todo_fail=$((todo_fail - 1)); fi
	done
fi

total=$((SENT[ok] + SENT[slow] + SENT[fail])); bad=$((BAD[ok] + BAD[slow] + BAD[fail]))
echo "load: total=$total ok=${SENT[ok]} slow=${SENT[slow]} fail=${SENT[fail]} errors=$bad" >&2
[ "$bad" -eq 0 ]
