#!/usr/bin/env bash
# F-M0-02 cluster-ingress-hosts 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make deploy && make hosts 가 끝난 상태.
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
var() { make --no-print-directory -s "print-$1" 2>/dev/null; }

CLUSTER_NAME="$(var CLUSTER_NAME)"
K3S_IMAGE="$(var K3S_IMAGE)"
CTX="k3d-${CLUSTER_NAME:-lgtm}"
NODE="k3d-${CLUSTER_NAME:-lgtm}-server-0"
HOSTS="lgtm.local grafana.lgtm.local ipfs.lgtm.local"
k() { kubectl --context "$CTX" "$@"; }

# 1. 노드 Ready + 버전이 K3S_IMAGE와 일치
# rancher/k3s:v1.37.1-k3s1 -> v1.37.1+k3s1
want="$(printf '%s' "${K3S_IMAGE##*:}" | sed 's/-k3s/+k3s/')"
nodes="$(k get nodes --no-headers 2>&1)"
if [ "$(printf '%s\n' "$nodes" | grep -c .)" -eq 1 ] && printf '%s\n' "$nodes" | awk '{print $2}' | grep -qx Ready; then
	pass "노드 1개 Ready"
else fail "노드 상태: $nodes"; fi
got="$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)"
if [ -n "$got" ] && [ "$got" = "$want" ]; then pass "노드 VERSION $got"; else fail "노드 VERSION: 기대 '$want' / 실제 '${got:-없음}'"; fi

# 2. 4001 tcp/udp 매핑 존재 (매핑 존재까지만. 외부 도달은 F-M3-01)
ports="$(scripts/lib/with-docker.sh docker port "$NODE" 2>&1)"
for p in 4001/tcp 4001/udp; do
	if printf '%s\n' "$ports" | grep -q "^$p -> "; then pass "docker port $NODE $p"; else fail "docker port $NODE 에 $p 없음: $ports"; fi
done

# 3. 호스트 이름 해석
for h in $HOSTS; do
	ip="$(getent hosts "$h" | awk '{print $1}' | head -1)"
	if [ "$ip" = "127.0.0.1" ]; then pass "getent hosts $h -> 127.0.0.1"; else fail "getent hosts $h -> '${ip:-해석 안 됨}'"; fi
done

# 4. 세 호스트 모두 200, 본문이 서로 다름
bodies=""
for h in $HOSTS; do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$h/" 2>/dev/null)"
	body="$(curl -sf --max-time 10 "http://$h/" 2>/dev/null)"
	if [ "$code" = "200" ] && [ -n "$body" ]; then pass "curl http://$h/ 200 [$body]"; else fail "curl http://$h/ code=${code:-없음}"; fi
	bodies+="$body"$'\n'
done
uniq_n="$(printf '%s' "$bodies" | grep -c . | xargs)"
distinct="$(printf '%s' "$bodies" | grep . | sort -u | wc -l | xargs)"
if [ "$uniq_n" -eq 3 ] && [ "$distinct" -eq 3 ]; then pass "응답 본문이 호스트별로 다름"; else fail "응답 본문 중복 또는 누락 (비어있지 않은 본문 $uniq_n, 서로 다른 본문 $distinct)"; fi

# 5. make cluster 재실행은 skip
out="$(make cluster 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "make cluster 재실행 exit 0" || fail "make cluster 재실행 exit $rc"
if printf '%s\n' "$out" | grep -q '^\[skip\] cluster '; then pass "make cluster 재실행 [skip]"; else fail "make cluster 재실행에 [skip] 없음"; fi
if printf '%s\n' "$out" | grep -q 'k3d cluster create'; then fail "재실행에서 클러스터 생성 시도"; else pass "재실행에서 클러스터 생성 안 함"; fi

# 6. make hosts 재실행 후 블록 1개
make hosts >/dev/null 2>&1 && make hosts >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "make hosts 2회 exit 0" || fail "make hosts exit $rc"
b="$(grep -c '^# BEGIN lgtm$' /etc/hosts)"; e="$(grep -c '^# END lgtm$' /etc/hosts)"
if [ "$b" -eq 1 ] && [ "$e" -eq 1 ]; then pass "/etc/hosts 블록 1개"; else fail "/etc/hosts BEGIN=$b END=$e (기대 1/1)"; fi

# 7. traefik IngressClass
k get ingressclass traefik >/dev/null 2>&1 && pass "IngressClass traefik" || fail "IngressClass traefik 없음"

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
