#!/usr/bin/env bash
# kubo-node 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태.
# 외부 gateway(ipfs.io) 도달은 m3-03 이 보므로 여기서 확인하지 않는다.
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
NS="ipfs"
POD="kubo-0"
PROBE_NS="ipfs-probe"
HOST="ipfs.lgtm.local"
k() { kubectl --context "$CTX" "$@"; }
kx() { k -n "$NS" exec "$POD" -c kubo -- "$@"; }
TMP="$(mktemp -d)"

restore_policies() { k apply -f k8s/ipfs/kubo.yaml >/dev/null 2>&1; }
cleanup() {
	k delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1
	k -n lgtm delete pod probe-backend --ignore-not-found --wait=false >/dev/null 2>&1
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

gw() { curl -s --max-time 15 --resolve "$HOST:80:127.0.0.1" "$@"; }
gcode() { gw -o /dev/null -w '%{http_code}' "$@"; }

# ---- 1. pod / PVC / 리소스 / 보안 설정 ----
ready="$(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="kubo")].ready}' 2>/dev/null)"
[ "$ready" = "true" ] && pass "kubo pod Ready" || fail "kubo pod Ready 아님 (ready='${ready}')"
img="$(k -n "$NS" get sts kubo -o jsonpath='{.spec.template.spec.containers[?(@.name=="kubo")].image}' 2>/dev/null)"
case "$img" in ipfs/kubo:v*) pass "이미지 태그 고정: $img" ;; *) fail "이미지='${img}' (ipfs/kubo:v<버전> 기대, :latest 금지)" ;; esac
lim="$(k -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[*].resources.limits.memory}/{.spec.containers[*].resources.requests.memory}/{.spec.containers[*].resources.limits.cpu}/{.spec.containers[*].resources.requests.cpu}' 2>/dev/null)"
IFS=/ read -r lm rm lc rc <<<"$lim"
[ -n "$lm" ] && [ -n "$rm" ] && [ -n "$lc" ] && [ -n "$rc" ] && pass "resources limit(mem/cpu)=$lm/$lc request=$rm/$rc" || fail "resources 누락: '${lim}'"
pvc="$(k -n "$NS" get pvc -o jsonpath='{.items[*].status.phase}' 2>/dev/null)"
[ "$pvc" = "Bound" ] && pass "PVC Bound" || fail "PVC phase='${pvc}'"
sc="$(k -n "$NS" get sts kubo -o jsonpath='{.spec.template.spec.automountServiceAccountToken}/{.spec.template.spec.securityContext.runAsNonRoot}/{.spec.template.spec.securityContext.seccompProfile.type}/{.spec.template.spec.containers[?(@.name=="kubo")].securityContext.allowPrivilegeEscalation}/{.spec.template.spec.containers[?(@.name=="kubo")].securityContext.capabilities.drop[0]}' 2>/dev/null)"
[ "$sc" = "false/true/RuntimeDefault/false/ALL" ] && pass "securityContext (automount false / runAsNonRoot / seccomp / noPrivEsc / drop ALL)" || fail "securityContext='${sc}'"
ro="$(k -n "$NS" get sts kubo -o jsonpath='{.spec.template.spec.containers[?(@.name=="kubo")].securityContext.readOnlyRootFilesystem}' 2>/dev/null)"
info "readOnlyRootFilesystem=${ro:-unset} (켜지 못했다면 HANDOFF 에 이유 기록)"
if [ "$ro" = "true" ]; then
	kx sh -c 'touch /rootfs-write-test 2>/dev/null' && fail "readOnlyRootFilesystem=true 인데 루트에 쓰기 성공" || pass "루트 파일시스템 쓰기 실패"
fi
uid="$(kx id -u 2>/dev/null)"
[ -n "$uid" ] && [ "$uid" != "0" ] && pass "kubo 프로세스 uid=$uid (root 아님)" || fail "kubo uid='${uid}'"
envs="$(k -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[?(@.name=="kubo")].env[*].name}={.spec.containers[?(@.name=="kubo")].env[*].value}' 2>/dev/null)"
case "$envs" in *IPFS_TELEMETRY*off*) pass "IPFS_TELEMETRY=off" ;; *) fail "IPFS_TELEMETRY=off 아님 ($envs)" ;; esac

# ---- 2. 설정 키 (init 단계 코드로 적용됐는지) ----
cfg() { kx ipfs config "$1" 2>/dev/null; }
v="$(cfg Gateway.PublicGateways | tr -d ' \n')"
case "$v" in *'"ipfs.lgtm.local"'*'"UseSubdomains":false'*) pass "Gateway.PublicGateways[ipfs.lgtm.local] UseSubdomains=false" ;; *) fail "Gateway.PublicGateways='${v}'" ;; esac
[ "$(cfg Gateway.NoFetch)" = "true" ] && pass "Gateway.NoFetch=true" || fail "Gateway.NoFetch!=true"
[ "$(cfg AutoTLS.Enabled)" = "false" ] && pass "AutoTLS.Enabled=false" || fail "AutoTLS.Enabled!=false"
v="$(cfg Swarm.ConnMgr | tr -d ' \n')"
case "$v" in *'"HighWater":60'*'"LowWater":20'*|*'"LowWater":20'*'"HighWater":60'*) pass "Swarm.ConnMgr 20/60" ;; *) fail "Swarm.ConnMgr='${v}'" ;; esac
v="$(cfg Swarm.ResourceMgr | tr -d ' \n')"
case "$v" in *MaxMemory*) pass "Swarm.ResourceMgr.MaxMemory 설정됨" ;; *) fail "Swarm.ResourceMgr='${v}'" ;; esac
[ "$(cfg Datastore.StorageMax)" = "4GB" ] && pass "Datastore.StorageMax=4GB" || fail "Datastore.StorageMax='$(cfg Datastore.StorageMax)'"

# ---- 3. ipfs add → gateway (path 방식, 301 아님) ----
MARK="lgtm-m3-01-$(date +%s)-$$"
CID="$(printf '%s' "$MARK" | k -n "$NS" exec -i "$POD" -c kubo -- ipfs add -Q --pin 2>/dev/null)"
[ -n "$CID" ] && pass "ipfs add → CID 얻음" || fail "ipfs add 실패"
code="$(gcode "http://$HOST/ipfs/$CID")"
[ "$code" = "200" ] && pass "gateway /ipfs/<CID> 200 (301 아님)" || fail "gateway /ipfs/<CID> code=${code}"
body="$(gw "http://$HOST/ipfs/$CID")"
[ "$body" = "$MARK" ] && pass "gateway 내용 일치" || fail "gateway 내용 불일치: '$(printf '%s' "$body" | head -c 100)'"

# ---- 4. 디렉토리 add → 목록 ----
DIR_CID="$(k -n "$NS" exec "$POD" -c kubo -- sh -c 'd=$(mktemp -d) && echo a >"$d/main.rs" && echo b >"$d/output.txt" && ipfs add -r -Q --pin "$d"' 2>/dev/null)"
[ -n "$DIR_CID" ] && pass "디렉토리 add → CID" || fail "디렉토리 add 실패"
list="$(gw "http://$HOST/ipfs/$DIR_CID/")"
case "$list" in *main.rs*output.txt*) pass "디렉토리 목록에 main.rs, output.txt 표시" ;; *) fail "디렉토리 목록 이상: '$(printf '%s' "$list" | head -c 200)'" ;; esac
code="$(gcode "http://$HOST/ipfs/$DIR_CID/main.rs")"
[ "$code" = "200" ] && pass "디렉토리 안 파일 200" || fail "디렉토리 안 파일 code=${code}"

# ---- 5. API 는 Ingress 로 노출되지 않는다 ----
code="$(gcode -X POST "http://$HOST/api/v0/id")"
[ "$code" != "200" ] && pass "ipfs.lgtm.local/api/v0/id (POST) 200 아님 (code=${code})" || fail "ipfs.lgtm.local/api/v0/id 가 200"
code="$(gcode "http://$HOST/api/v0/id")"
[ "$code" != "200" ] && pass "ipfs.lgtm.local/api/v0/id (GET) 200 아님 (code=${code})" || fail "ipfs.lgtm.local/api/v0/id (GET) 가 200"
ports="$(k get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{range .http.paths[*]}{.backend.service.port.number}{" "}{end}{end}{end}' 2>/dev/null)"
case " $ports " in *" 5001 "*) fail "어떤 Ingress 가 5001 을 가리킴" ;; *) pass "Ingress 중 5001 backend 없음" ;; esac

# ---- 6. NoFetch: 로컬에 없는 CID → 10초 안에 4xx (오픈 프록시 아님) ----
MISSING="$(printf 'not-stored-%s-%s' "$$" "$(date +%s%N)" | k -n "$NS" exec -i "$POD" -c kubo -- ipfs add -Q --only-hash 2>/dev/null)"
t0=$SECONDS
code="$(gw --max-time 12 -o /dev/null -w '%{http_code}' "http://$HOST/ipfs/$MISSING")"
dt=$((SECONDS - t0))
case "$code" in 4??) [ "$dt" -le 10 ] && pass "없는 CID → ${code} (${dt}s)" || fail "없는 CID 응답이 ${dt}s 걸림 (code=${code})" ;; *) fail "없는 CID code=${code} (4xx 기대, ${dt}s)" ;; esac

# ---- 7. NetworkPolicy: API 5001 은 backend(lgtm, app=backend)에서만 ----
IMG="$img"
k delete ns "$PROBE_NS" --ignore-not-found --wait=true >/dev/null 2>&1
k create ns "$PROBE_NS" >/dev/null 2>&1 || fail "probe namespace 생성 실패"
mkpod() { # <ns> <name> <labels yaml>
	cat <<YAML | k -n "$1" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $2, labels: {$3}}
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
}
k -n "$PROBE_NS" delete pod probe --ignore-not-found --wait=true >/dev/null 2>&1
k -n lgtm delete pod probe-backend --ignore-not-found --wait=true >/dev/null 2>&1
mkpod "$PROBE_NS" probe 'role: probe'
mkpod lgtm probe-backend 'app: backend'
k -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=90s >/dev/null 2>&1 || fail "probe pod Ready 아님"
k -n lgtm wait --for=condition=Ready pod/probe-backend --timeout=90s >/dev/null 2>&1 || fail "probe-backend pod Ready 아님"
# 연결 성공 = HTTP 응답을 받음 (코드 무관). 연결 실패/timeout = 응답 없음
conn() { # <ns> <pod> <port>
	k -n "$1" exec "$2" -- sh -c "wget -T 4 -S -O- --post-data= http://kubo-api.$NS.svc.cluster.local:$3/api/v0/id 2>&1 | grep -q 'HTTP/'" >/dev/null 2>&1
}
wait_state() { # <ns> <pod> <port> <ok|blocked> → 최대 40s 폴링
	local i
	for i in $(seq 1 20); do
		if conn "$1" "$2" "$3"; then [ "$4" = ok ] && return 0; else [ "$4" = blocked ] && return 0; fi
		sleep 2
	done
	return 1
}
k -n "$PROBE_NS" exec probe -- true >/dev/null 2>&1 || { fail "probe pod exec 불가 (이후 차단 판정 무효)"; }
wait_state "$PROBE_NS" probe 5001 blocked && pass "다른 namespace pod → kubo-api:5001 연결 실패" || fail "다른 namespace pod 가 kubo-api:5001 에 연결됨 (정책 미강제?)"
wait_state lgtm probe-backend 5001 ok && pass "lgtm/app=backend pod → kubo-api:5001 연결 성공" || fail "lgtm/app=backend pod 가 kubo-api:5001 에 연결 실패"
# gateway 8080 은 다른 namespace 에서도 허용
k -n "$PROBE_NS" exec probe -- sh -c "wget -T 4 -S -O- http://kubo-gateway.$NS.svc.cluster.local:8080/ipfs/$CID 2>&1 | grep -q 'HTTP/1.[01] 200'" >/dev/null 2>&1 \
	&& pass "다른 namespace pod → gateway:8080 허용" || fail "다른 namespace pod → gateway:8080 실패"
k -n "$NS" delete netpol --all >/dev/null 2>&1
wait_state "$PROBE_NS" probe 5001 ok && pass "대조군: 정책 삭제 시 같은 pod 연결 성공 (정책이 실제로 차단 중이었음)" || fail "대조군: 정책을 지워도 연결 실패 (실패 원인이 정책이 아님)"
restore_policies
wait_state "$PROBE_NS" probe 5001 blocked && pass "정책 복구 후 다시 연결 실패" || fail "정책 복구 후에도 연결됨"

# ---- 8. swarm: peers > 0 (VM 인터넷 필요, 최대 180s), listen 주소, 호스트 4001 ----
peers=0
for i in $(seq 1 36); do
	peers="$(kx ipfs swarm peers 2>/dev/null | grep -c .)"
	[ "${peers:-0}" -gt 0 ] && break
	sleep 5
done
[ "${peers:-0}" -gt 0 ] && pass "swarm peers=${peers} (>0)" || fail "swarm peers=0 (180s, VM 인터넷 확인)"
idj="$(kx ipfs id -f='<addrs>' 2>/dev/null)"
case "$idj" in *"/tcp/4001/p2p/"*) pass "ipfs id: tcp 4001 listen" ;; *) fail "ipfs id 에 /tcp/4001 없음" ;; esac
case "$idj" in *"/udp/4001/quic-v1/"*) pass "ipfs id: udp 4001 quic-v1 listen" ;; *) fail "ipfs id 에 /udp/4001/quic-v1 없음" ;; esac
hp="$(k -n "$NS" get pod "$POD" -o jsonpath='{range .spec.containers[*].ports[*]}{.hostPort}/{.protocol}{" "}{end}' 2>/dev/null)"
case "$hp" in *"4001/TCP"*"4001/UDP"*|*"4001/UDP"*"4001/TCP"*) pass "hostPort 4001 TCP/UDP: $hp" ;; *) fail "hostPort='${hp}'" ;; esac
ss -lnt 2>/dev/null | grep -q ':4001 ' && pass "VM 호스트 4001/tcp listen" || fail "VM 호스트 4001/tcp listen 안 함"
ss -lnu 2>/dev/null | grep -q ':4001 ' && pass "VM 호스트 4001/udp listen" || fail "VM 호스트 4001/udp listen 안 함"
# 호스트 127.0.0.1:4001 (docker-proxy → k3d 노드 → hostPort → kubo): multistream 헤더를 보내고 같은 헤더가 돌아오는지 본다
hdr="$(timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4001; printf "\\023/multistream/1.0.0\\n" >&3; head -c 20 <&3' 2>/dev/null | tr -d '\0-\037')"
case "$hdr" in */multistream/1.0.0*) pass "호스트 127.0.0.1:4001 → kubo multistream 응답 ($hdr)" ;; *) fail "호스트 4001 에서 multistream 응답 없음: '${hdr}'" ;; esac

# ---- 9. pod 재시작 후 PVC 데이터 유지 ----
k -n "$NS" delete pod "$POD" --wait=true >/dev/null 2>&1
k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null 2>&1 || fail "재시작 후 pod Ready 아님"
ok=""
for i in $(seq 1 30); do
	body="$(gw "http://$HOST/ipfs/$CID")"
	[ "$body" = "$MARK" ] && { ok=1; break; }
	sleep 2
done
[ -n "$ok" ] && pass "pod 재시작 후 같은 CID 조회 성공 (PVC 유지)" || fail "pod 재시작 후 CID 조회 실패"
pin="$(kx ipfs pin ls --type=recursive "$CID" 2>/dev/null | grep -c "$CID")"
[ "${pin:-0}" -ge 1 ] && pass "재시작 후 pin 유지" || fail "재시작 후 pin 없음"

# ---- 10. dummy-ipfs 제거 ----
left="$(k -n dummy get deploy,svc,ingress dummy-ipfs -o name 2>/dev/null)"
[ -z "$left" ] && pass "dummy-ipfs 리소스 없음" || fail "dummy-ipfs 리소스가 남아 있음: $left"
[ ! -e k8s/dummy/ipfs.yaml ] && pass "k8s/dummy/ipfs.yaml 삭제됨" || fail "k8s/dummy/ipfs.yaml 이 남아 있음"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m3-01)"; exit 0; fi
echo "FAILED: ${fails}건 (m3-01)" >&2
exit 1
