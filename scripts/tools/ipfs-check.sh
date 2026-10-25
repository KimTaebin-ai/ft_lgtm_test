#!/usr/bin/env bash
# make ipfs-check: "우리 노드가 올린 CID 를 public gateway 에서 열 수 있나" 진단.
# 네트워크 상태에 의존하므로 make all 에 넣지 않는다. public 쪽 실패는 결과일 뿐 exit 0 (kubo 를 못 쓰면 exit 1).
# 출력 형식: [ipfs-check] S<n> PASS|FAIL|INFO|SKIP <내용> / GATEWAY / CID / SUMMARY (scripts/verify/m3-03-external-gateway.sh 가 검사)
# 근거: Kubo RPC https://docs.ipfs.tech/reference/kubo/rpc/ (swarm/addrs/autonat, provide/once),
#       delegated routing https://specs.ipfs.tech/routing/http-routing-v1/, ipfs-check https://github.com/ipfs/ipfs-check
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

CLUSTER_NAME="${CLUSTER_NAME:-lgtm}"
CTX="k3d-${CLUSTER_NAME}"
NODE="k3d-${CLUSTER_NAME}-server-0"
LOCAL_GW="ipfs.lgtm.local"
# VM 에서 실제로 요청해 확인한 것만. 응답이 오류여도 "gateway 가 응답했다"는 증거라 목록에 둔다
GATEWAYS=(ipfs.io dweb.link gateway.pinata.cloud trustless-gateway.link 4everland.io)
GW_MAX_TIME="${IPFS_CHECK_GW_MAX_TIME:-90}"
DELEGATED_WAIT="${IPFS_CHECK_DELEGATED_WAIT:-60}"
BACKEND_MAX_TIME="${IPFS_CHECK_BACKEND_MAX_TIME:-90}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null' EXIT INT TERM

res() { printf '[ipfs-check] %s %s %s\n' "$1" "$2" "$3"; }
kx() { kubectl --context "$CTX" -n ipfs exec kubo-0 -c kubo -- "$@"; }
# VM 에는 global IPv6 가 없어 AAAA 만 우선 선택되는 host 가 있다 → curl -4
cu() { curl -4 -s "$@"; }

if ! kx ipfs version >/dev/null 2>&1; then
	echo "ERROR: kubo-0 에 접근할 수 없음 (make deploy 후 실행, context=$CTX)" >&2
	exit 1
fi
PID="$(kx ipfs config Identity.PeerID 2>/dev/null)"
echo "[ipfs-check] PEERID $PID"
echo "[ipfs-check] $(kx ipfs version)"

adv_fail=""
blocked=""      # 첫 막힌 층
reason=""
block() { [ -z "$blocked" ] && { blocked="$1"; reason="$2"; }; }

# ---- S1 VM 내부 4001 ----
s1=PASS; d1=""
listen="$(kx ipfs swarm addrs listen 2>/dev/null)"
echo "$listen" | grep -q '/tcp/4001' && echo "$listen" | grep -q '/udp/4001/quic-v1' && d1="kubo listen tcp+quic-v1 4001" || { s1=FAIL; d1="kubo 가 4001 tcp/quic listen 안 함"; }
port="$(bash scripts/lib/with-docker.sh docker port "$NODE" 4001 2>/dev/null | tr '\n' ' ')"
case "$port" in *4001/tcp*|*0.0.0.0:4001*) d1="$d1; docker 매핑 ${port}" ;; *) s1=FAIL; d1="$d1; docker 4001 매핑 없음" ;; esac
hdr="$(timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4001; printf "\023/multistream/1.0.0\n" >&3; head -c 20 <&3' 2>/dev/null | tr -d '\0-\037')"
case "$hdr" in */multistream/1.0.0*) d1="$d1; 호스트 127.0.0.1:4001 multistream 응답" ;; *) s1=FAIL; d1="$d1; 호스트 4001 multistream 응답 없음" ;; esac
res S1 "$s1" "$d1"
[ "$s1" = FAIL ] && block vm-4001 "$d1"

# ---- S2 swarm peers ----
peers="$(kx ipfs swarm peers 2>/dev/null | grep -c .)"
if [ "$peers" -gt 0 ]; then res S2 PASS "swarm peers=$peers (아웃바운드 연결 가능)"; else res S2 FAIL "swarm peers=0 (아웃바운드부터 막힘)"; block internet "swarm peers=0"; fi

# ---- S3 우리 주소 (외부에서 어떻게 보이나) ----
addrs="$(kx ipfs id -f='<addrs>' 2>/dev/null)"
relay_n="$(echo "$addrs" | grep -c '/p2p-circuit')"
relay_peers="$(echo "$addrs" | grep '/p2p-circuit' | sed -n 's#.*/p2p/\([^/]*\)/p2p-circuit.*#\1#p' | sort -u | wc -l)"
nocirc="$(echo "$addrs" | grep -v '/p2p-circuit')"
private_re='^/ip4/(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)|^/ip6/(::1/|f[cd]|fe80)'
direct_pub="$(echo "$nocirc" | grep -Ev "$private_re" | grep -c '^/ip')"
priv_n="$(echo "$nocirc" | grep -Ec "$private_re")"
protos="$(kx ipfs id -f='<protocols>' 2>/dev/null)"
has_dcutr=no; echo "$protos" | grep -q '/libp2p/dcutr' && has_dcutr=yes
has_relay_stop=no; echo "$protos" | grep -q '/libp2p/circuit/relay/0.2.0/stop' && has_relay_stop=yes
res S3 INFO "공인 직접 주소=$direct_pub, 사설/loopback=$priv_n, relay(/p2p-circuit) 주소=$relay_n (relay 노드 ${relay_peers}개), dcutr(hole punching) 프로토콜=$has_dcutr, relay client(stop) 프로토콜=$has_relay_stop"

# ---- S4 reachability (AutoNAT v2) ----
reach="$(kx ipfs swarm addrs autonat --enc=json 2>/dev/null | sed -n 's/.*"reachability":"\([^"]*\)".*/\1/p')"
reach="${reach:-unknown}"
case "$reach" in
	Public|public) res S4 PASS "AutoNAT reachability=$reach (밖에서 직접 접속 가능)" ;;
	*) res S4 FAIL "AutoNAT reachability=$reach (밖에서 4001 로 직접 접속 못 함, 공인 직접 주소 ${direct_pub}개)" ;;
esac

# ---- S5 테스트 파일 add + pin + provide (내용에 시각 포함, 10kB 미만) ----
FILE="$TMP/probe.txt"
{ printf 'lgtm ipfs-check %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RANDOM$RANDOM"; head -c 6600 /dev/urandom | base64 -w0; echo; } >"$FILE"
size="$(wc -c <"$FILE")"
CID="$(kubectl --context "$CTX" -n ipfs exec -i kubo-0 -c kubo -- ipfs add -Q --pin <"$FILE" 2>/dev/null)"
if [ -z "$CID" ]; then
	res S5 FAIL "ipfs add 실패"; res S6 SKIP "CID 없음"; res S7 SKIP "CID 없음"; res S8 SKIP "CID 없음"; res S9 SKIP "CID 없음"
	echo "[ipfs-check] SUMMARY first_blocked=unknown reason=ipfs add 실패"
	exit 1
fi
pin="$(kx ipfs pin ls --type=recursive "$CID" 2>/dev/null | head -1)"
prov="$(kx ipfs provide once "$CID" 2>&1 | head -1)"
res S5 PASS "add+pin+provide: ${size}B pin='${pin:+yes}' provide='${prov}'"
echo "[ipfs-check] CID $CID"

# ---- S6 로컬 gateway ----
cu -m 15 --resolve "$LOCAL_GW:80:127.0.0.1" -o "$TMP/local.out" -w '%{http_code}' "http://$LOCAL_GW/ipfs/$CID" >"$TMP/local.code"
if [ "$(cat "$TMP/local.code")" = 200 ] && cmp -s "$TMP/local.out" "$FILE"; then res S6 PASS "http://$LOCAL_GW/ipfs/$CID 200, 내용 일치"; else res S6 FAIL "로컬 gateway code=$(cat "$TMP/local.code")"; fi

# S8, S9 는 오래 걸리므로 S7 과 동시에 시작한다 (provide 직후 DHT 반영 전에 시작하면 일부 gateway 는 실패할 수 있어 S7 이 PASS 한 뒤 시작)
# ---- S7 "광고됨": delegated routing 에 우리 PeerID 가 provider 로 나오는가 ----
found=""; body=""; waited=0
while :; do
	body="$(cu -m 15 -H 'Accept: application/json' "https://delegated-ipfs.dev/routing/v1/providers/$CID")"
	if printf '%s' "$body" | grep -Fq "\"ID\":\"$PID\""; then found=1; break; fi
	[ "$waited" -ge "$DELEGATED_WAIT" ] && break
	sleep 10; waited=$((waited + 10))
done
if [ -n "$found" ]; then
	pa="$(printf '%s' "$body" | grep -o '"Addrs":\[[^]]*\]' | head -1)"
	kind="직접 주소 포함"; [ "$(printf '%s' "$pa" | sed 's/^"Addrs":\[//; s/\]$//' | tr ',' '\n' | grep -c '/ip')" -gt 0 ] && [ "$(printf '%s' "$pa" | sed 's/^"Addrs":\[//; s/\]$//' | tr ',' '\n' | grep '/ip' | grep -vc '/p2p-circuit')" -eq 0 ] && kind="relay(/p2p-circuit) 주소만"
	res S7 PASS "delegated routing 에 광고됨 (${waited}s 후, $kind) ${pa:0:300}"
else
	res S7 FAIL "delegated routing 에 우리 PeerID 없음 (${DELEGATED_WAIT}s 대기, 응답 '${body:0:120}') = provide 가 DHT 에 반영 안 됨"
	adv_fail=1 # 광고 지연은 NAT 층 판정보다 뒤 (S4 Private 이면 층 판정은 그쪽을 우선하고 reason 에만 덧붙인다)
fi

# ---- S8 "도달 가능": 외부 ipfs-check 백엔드가 우리에게 접속해 블록을 받는가 / S9 public gateway ----
(
	cu -m "$BACKEND_MAX_TIME" -w '\nHTTP %{http_code}' "https://ipfs-check-backend.ipfs.io/check?cid=$CID&multiaddr=/p2p/$PID" >"$TMP/s8.out" 2>/dev/null
	echo $? >"$TMP/s8.rc"
) &
i=0
for g in "${GATEWAYS[@]}"; do
	i=$((i + 1))
	(
		cu -L -m "$GW_MAX_TIME" --connect-timeout 10 -o "$TMP/gw$i.body" -w '%{http_code} %{time_total}' "https://$g/ipfs/$CID" >"$TMP/gw$i.res" 2>/dev/null
		[ -s "$TMP/gw$i.res" ] || echo "000 0" >"$TMP/gw$i.res"
	) &
done
wait

s8rc="$(cat "$TMP/s8.rc" 2>/dev/null || echo 99)"; s8="$(cat "$TMP/s8.out" 2>/dev/null)"
reachable_ext=""
if [ "$s8rc" != 0 ] || [ -z "$s8" ]; then
	res S8 SKIP "ipfs-check 백엔드 응답 없음 (curl rc=$s8rc, ${BACKEND_MAX_TIME}s; rc=28 은 timeout). 이 VM 네트워크에서 백엔드에 접속하지 못해 판정 불가"
else
	cerr="$(printf '%s' "$s8" | grep -o '"ConnectionError":"[^"]*"' | head -1)"
	if printf '%s' "$s8" | grep -Eq '"Found":\s*true'; then reachable_ext=1; res S8 PASS "외부에서 접속해 블록 수신 (Bitswap Found=true) ${cerr}"
	else res S8 FAIL "외부에서 블록 못 받음 ${cerr:-(오류 필드 없음)} raw=$(printf '%s' "$s8" | tr -d '\n' | head -c 300)"; fi
fi

ok_n=0; noconn_n=0; policy_n=0; i=0; gw_lines=()
for g in "${GATEWAYS[@]}"; do
	i=$((i + 1))
	read -r code secs <"$TMP/gw$i.res"
	verdict=fail; note=""
	if [ "$code" = 200 ] && cmp -s "$TMP/gw$i.body" "$FILE"; then verdict=ok; ok_n=$((ok_n + 1))
	elif [ "$code" = 200 ]; then verdict=mismatch; note="본문 불일치"
	elif [ "$code" = 000 ]; then verdict=noconn; noconn_n=$((noconn_n + 1)); note="연결/DNS 실패 (gateway 쪽 또는 VM DNS, NAT 와 무관)"
	elif { [ "$code" = 429 ] || [ "$code" = 403 ]; } && grep -Eqi 'service worker|blocked' "$TMP/gw$i.body" 2>/dev/null; then verdict=policy; policy_n=$((policy_n + 1)); note="gateway 정책(HTTP 요청 차단/service worker 전용), NAT 와 무관"
	else note="$(head -c 100 "$TMP/gw$i.body" 2>/dev/null | tr '\n' ' ')"; fi
	printf '[ipfs-check] GATEWAY %s %s %.1fs %s %s\n' "$g" "$code" "$secs" "$verdict" "$note"
done
real=$(( ${#GATEWAYS[@]} - noconn_n - policy_n ))
if [ "$ok_n" -gt 0 ]; then res S9 PASS "public gateway ${ok_n}/${#GATEWAYS[@]} 곳에서 열림"
else res S9 FAIL "public gateway 0/${#GATEWAYS[@]} (연결 불가 ${noconn_n}, 정책 차단 ${policy_n}, 실제로 조회해 실패 ${real})"; fi

# ---- 층 판정에 쓰는 단서 (VM 안에서 확인 가능한 것만) ----
gwip="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
hops="도구 없음"
if command -v traceroute >/dev/null 2>&1; then
	hops="$(timeout 30 traceroute -n -m 6 -w 1 -q 1 1.1.1.1 2>/dev/null | awk 'NR>1{print $2}' | awk -v re='^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)' '$1=="*"{next} $1~re{n++; next} {print n+0; found=1; exit} END{if(!found) print (n+0) "+"}')"
fi
res INFO CLUE "VM 기본 게이트웨이=${gwip:-없음}, 첫 공인 IP 이전 사설 hop 수=${hops} (traceroute 1.1.1.1)"

# ---- SUMMARY ----
if [ -z "$blocked" ]; then
	case "$reach" in
		Public|public)
			if [ -n "$adv_fail" ]; then blocked=internet; reason="직접 도달 가능인데 delegated routing 에 광고 안 됨 (provide 가 DHT 에 반영되지 않음)"
			elif [ "$ok_n" -gt 0 ]; then blocked=none; reason="직접 도달 가능, gateway ${ok_n}곳 성공"
			else blocked=internet; reason="직접 도달 가능한데 gateway 에서 안 열림 (gateway 쪽 정책/전파 지연: 연결 불가 ${noconn_n}, 정책 차단 ${policy_n})"; fi ;;
		*)
			case "$gwip" in
				192.168.64.*|10.0.2.*) blocked=utm; reason="inferred: AutoNAT=$reach, 공인 직접 주소 ${direct_pub}개, 기본 게이트웨이 ${gwip} 는 UTM NAT 대역 (이 VM 에서 UTM 과 공유기를 구분해 증명할 수는 없음)" ;;
				10.*|172.1[6-9].*|172.2?.*|172.3[01].*|192.168.*) blocked=router; reason="inferred: AutoNAT=$reach, 기본 게이트웨이 ${gwip} 가 사설 LAN (공유기 포트포워딩 필요)" ;;
				*) blocked=internet; reason="AutoNAT=$reach 인데 VM 이 공인 게이트웨이 ${gwip:-없음} 뒤에 있음 (방화벽/ISP)" ;;
			esac
			[ -n "$adv_fail" ] && reason="$reason; S7 은 ${DELEGATED_WAIT}s 안에 광고가 안 보였음(DHT 반영 지연일 수 있음, 실행마다 0~30s 또는 미반영으로 달랐음)"
			if [ "$ok_n" -gt 0 ]; then reason="$reason; 단 relay 경유로 gateway ${ok_n}곳 성공"; fi
			if [ -n "$reachable_ext" ]; then reason="$reason; 단 외부 프로브는 성공"; fi ;;
	esac
fi
echo "[ipfs-check] SUMMARY first_blocked=$blocked reason=$reason"
echo "[ipfs-check] 층 순서: VM 내부 4001 → UTM(Mac) → 공유기 → 인터넷. utm/router 는 VM 안에서 추정만 가능, 확정은 UTM·공유기 설정 확인"
exit 0
