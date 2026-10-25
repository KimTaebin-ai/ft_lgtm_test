#!/usr/bin/env bash
# 재부팅 내성 확인 (F-M6-02). VM 재부팅 직후 로그인해서 실행한다.
# 부팅 시각(/proc/uptime) 기준 LIMIT 초 안에 (1) kubectl get pods -A 가 전부 Running(+Ready) 또는 Completed,
# (2) curl --resolve 로 lgtm.local 200 이 되면 PASS. 상태는 2초마다 본다.
# usage: scripts/tools/reboot-check.sh [LIMIT초, 기본 180]
set -u

LIMIT="${1:-180}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
CTX="k3d-$(make --no-print-directory -s print-CLUSTER_NAME 2>/dev/null)"

uptime_s() { cut -d. -f1 /proc/uptime; }

# 준비 안 된 pod 를 "ns/name status ready" 로 출력한다. 하나도 없고 pod 목록이 비어 있지 않으면 성공
not_ready() {
	local out
	out="$(kubectl --context "$CTX" get pods -A --no-headers 2>&1)" || { echo "kubectl: $out" | head -1; return; }
	[ -n "$out" ] || { echo "pod 없음"; return; }
	printf '%s\n' "$out" | awk '
		$4 == "Completed" { next }
		$4 == "Running" { split($3, r, "/"); if (r[1] == r[2]) next }
		{ print $1 "/" $2, $4, $3 }'
}

echo "부팅 후 $(uptime_s)s, 상한 ${LIMIT}s"
code=""
while :; do
	t="$(uptime_s)"
	bad="$(not_ready)"
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve lgtm.local:80:127.0.0.1 http://lgtm.local/ 2>/dev/null)"
	if [ -z "$bad" ] && [ "$code" = "200" ]; then
		echo "PASS: 부팅 후 ${t}s 에 모든 pod Running/Completed, lgtm.local 200"
		kubectl --context "$CTX" get pods -A
		exit 0
	fi
	if [ "$t" -ge "$LIMIT" ]; then
		echo "FAIL: 부팅 후 ${LIMIT}s 안에 준비되지 않음 (lgtm.local HTTP ${code:-없음})" >&2
		[ -z "$bad" ] || printf '준비 안 된 pod:\n%s\n' "$bad" >&2
		kubectl --context "$CTX" get pods -A >&2
		exit 1
	fi
	sleep 2
done
