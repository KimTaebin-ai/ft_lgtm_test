# verify 스크립트 공용 port-forward 헬퍼. source 해서 쓴다 (직접 실행 대상이 아니다).
# 전제: 호출 스크립트가 k() 를 정의했다. 정리는 호출 스크립트의 trap 이 pf_stop 을 부른다.
# 로컬 포트는 스크립트마다 겹치지 않는 값을 쓴다 (m1-01 ~ m2-02 가 각자 +1000*번호 대역).

PF_PIDS=()
PF_LOG_DIR="${PF_LOG_DIR:-}"
PF_LOG_OWN=0

pf_stop() {
	local p
	for p in "${PF_PIDS[@]:-}"; do
		[ -n "$p" ] && kill "$p" 2>/dev/null
	done
	wait "${PF_PIDS[@]:-}" 2>/dev/null
	PF_PIDS=()
	if [ "$PF_LOG_OWN" = 1 ]; then rm -rf "$PF_LOG_DIR"; PF_LOG_DIR=""; PF_LOG_OWN=0; fi
	return 0
}

# pf_forward <ns> <svc 이름 | 종류/이름> <local>:<remote>...
# 반환 조건: kubectl 이 살아 있고, 그 kubectl 이 로컬 포트를 실제로 열었고(출력의 Forwarding 줄),
# 포트마다 HTTP 응답(코드 != 000)을 받았을 때. 최대 30초. 실패 시 kubectl 출력을 stderr 로 남긴다.
pf_forward() {
	local ns="$1" res="$2"
	shift 2
	case "$res" in */*) ;; *) res="svc/$res" ;; esac
	if [ -z "$PF_LOG_DIR" ]; then PF_LOG_DIR="$(mktemp -d)"; PF_LOG_OWN=1; fi
	local log="$PF_LOG_DIR/pf-${1%%:*}.log" pid m port code i
	k -n "$ns" port-forward "$res" "$@" >"$log" 2>&1 &
	pid=$!
	PF_PIDS+=("$pid")
	for m in "$@"; do
		port="${m%%:*}"
		for i in $(seq 1 30); do
			if ! kill -0 "$pid" 2>/dev/null; then
				echo "port-forward($ns $res $m) 종료됨: $(tr '\n' ' ' <"$log")" >&2
				return 1
			fi
			if grep -q "127.0.0.1:$port ->" "$log"; then
				code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null)"
				[ -n "$code" ] && [ "$code" != "000" ] && continue 2
			fi
			sleep 1
		done
		echo "port-forward($ns $res $m) 30초 안에 HTTP 응답 없음: $(tr '\n' ' ' <"$log")" >&2
		return 1
	done
	return 0
}
