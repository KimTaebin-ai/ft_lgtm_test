#!/usr/bin/env bash
# F-M2-02 compiler-hardening 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다.
# 15초 timeout 재현은 m2-01.sh 와 같이 단위 테스트로 대체한다.
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
PROBE_NS="lgtm-probe"
HOST="lgtm.local"
k() { kubectl --context "$CTX" "$@"; }
TMP="$(mktemp -d)"

# 정책을 임시로 지우는 검사(4b)가 중단돼도 항상 복구한다 (idempotent)
restore_policies() {
	local img
	img="$(k -n "$NS" get deploy compiler -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
	[ -n "$img" ] && sed "s|__COMPILER_IMAGE__|$img|" k8s/app/compiler.yaml | k apply -f - >/dev/null 2>&1
}
cleanup() { restore_policies; k delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

lurl() { curl -s --max-time 60 --resolve "$HOST:80:127.0.0.1" "$@"; }
pyj() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1" 2>/dev/null; }
req_body() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$1"; }
post() { req_body "$1" | lurl -X POST -H 'Content-Type: application/json' --data-binary @- "http://$HOST/api/execute"; }

# ---- 1. 공격 코드 → compile_error + 차단 규칙 표시 + 유출 없음 ----
# attack <이름> <기대 규칙 ID> <소스>
attack() {
	local name="$1" rule="$2" code="$3" body st err
	body="$(post "$code")"
	st="$(printf '%s' "$body" | pyj "d['status']")"
	err="$(printf '%s' "$body" | pyj "d.get('stderr','')+d.get('message','')")"
	if [ "$st" != "compile_error" ]; then fail "공격 [$name] status='${st}' (기대 compile_error)"; return; fi
	case "$err" in *"LGTM 소스 정책 위반 [$rule]"*) ;; *) fail "공격 [$name] 메시지에 규칙 [$rule] 없음: $(printf '%s' "$err" | head -c 200)"; return ;; esac
	case "$body" in *root:x:0:0*) fail "공격 [$name] 응답에 /etc/passwd 내용 유출"; return ;; esac
	pass "공격 차단 [$name] → compile_error [$rule], 유출 없음"
}
attack 'include_str!'        deny-include-macro 'fn main() { println!("{}", include_str!("/etc/passwd")); }'
attack 'include_str !('      deny-include-macro 'fn main() { println!("{}", include_str !("/etc/passwd")); }'
attack 'core::include_str!'  deny-include-macro 'fn main() { println!("{}", core::include_str!("/etc/passwd")); }'
attack 'r#include_str!'      deny-include-macro 'fn main() { println!("{}", r#include_str!("/etc/passwd")); }'
attack 'include!'            deny-include-macro 'fn main() { let _ = include!("/etc/passwd"); }'
attack 'env!'                deny-env-macro     'fn main() { println!("{}", env!("PATH")); }'
attack 'macro_rules m!(env)' deny-env-macro     'macro_rules! m { ($n:ident) => { $n!("PATH") }; } fn main() { println!("{}", m!(env)); }'
attack 'path attr mod'       deny-mod-file      '#[path = "/proc/self/environ"] mod x; fn main() {}'
attack 'cfg_attr path mod'   deny-mod-file      '#[cfg_attr(all(), path = "/proc/self/environ")] mod x; fn main() {}'
attack 'use as + x!'         deny-include-macro 'use std::include_str as x; fn main() { println!("{}", x!("/etc/passwd")); }'
attack 'nested comment gap'  deny-include-macro 'fn main() { let s = "//"; println!("{}{}", s, include_str /* /* */ */ !("/etc/passwd")); }'
attack 'incbin'              deny-incbin        'fn main() { let _ = ".incbin \"/etc/passwd\""; }'

# ---- 2. 정상 예제 → success (회귀 없음) ----
NORMAL='use std::collections::HashMap;
trait Shape { fn area(&self) -> f64; }
struct Sq(f64);
impl Shape for Sq { fn area(&self) -> f64 { self.0 * self.0 } }
mod inner { pub fn twice(x: u32) -> u32 { x * 2 } }
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = "a/b";
    let mut m = HashMap::new();
    for (i, v) in (1..=3).map(|x| inner::twice(x)).enumerate() { m.insert(i, v); }
    println!("{} {} {:?} {}", args.len(), path, m.len(), Sq(2.0).area());
}'
body="$(post "$NORMAL")"
v="$(printf '%s' "$body" | pyj "d['status']")"
[ "$v" = "success" ] && pass "정상 예제 (struct/trait/iterator/std::env::args) → success" || fail "정상 예제 status='${v}' body=$(printf '%s' "$body" | head -c 300)"

# ---- 3. 격리 계층 단독 (deny-list 가 뚫렸다고 가정) ----
cx() { k -n "$NS" exec deploy/compiler -- "$@"; }
envs="$(cx env 2>&1)"
if printf '%s\n' "$envs" | grep -Eiq '_SERVICE_HOST|_SERVICE_PORT|_PORT=tcp://|KUBERNETES|TOKEN|SECRET|PASSWORD'; then
	fail "compiler 환경변수에 Service 주소/비밀값: $(printf '%s\n' "$envs" | grep -Ei '_SERVICE_|_PORT=tcp|KUBERNETES|TOKEN|SECRET|PASSWORD' | head -3)"
else pass "compiler 환경변수에 다른 Service 주소·비밀값 없음"; fi
cx test -e /var/run/secrets/kubernetes.io 2>/dev/null && fail "/var/run/secrets/kubernetes.io 존재" || pass "/var/run/secrets/kubernetes.io 없음"
cx sh -c 'touch /rootfs-write-test 2>/dev/null' && fail "루트 파일시스템에 쓰기 성공" || pass "루트 파일시스템 쓰기 실패 (readOnlyRootFilesystem)"
cx sh -c 'f=$(mktemp -p /work) && rm -f "$f"' >/dev/null 2>&1 && pass "/work (emptyDir) 쓰기 성공" || fail "/work 쓰기 실패"
tcp() { cx timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; } # 성공 0
tcp 1.1.1.1 80 && fail "외부 1.1.1.1:80 연결 성공" || pass "외부 1.1.1.1:80 연결 실패"
tcp backend.lgtm.svc.cluster.local 80 && fail "backend Service 연결 성공" || pass "backend Service 연결 실패"
tcp otel-collector.observability.svc.cluster.local 4317 && pass "otel-collector:4317 연결 성공" || fail "otel-collector:4317 연결 실패"

# ---- 4. NetworkPolicy 강제 실측 ----
k create ns "$PROBE_NS" >/dev/null 2>&1 || true
IMG="$(k -n "$NS" get deploy compiler -o jsonpath='{.spec.template.spec.containers[0].image}')"
k -n "$PROBE_NS" delete pod probe --ignore-not-found --wait=true >/dev/null 2>&1
cat <<YAML | k -n "$PROBE_NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: probe}
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
k -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=90s >/dev/null 2>&1 || fail "probe pod Ready 아님"
ptcp() { k -n "$PROBE_NS" exec probe -- timeout 4 bash -c "exec 3<>/dev/tcp/compiler.lgtm.svc.cluster.local/80" >/dev/null 2>&1; }
wait_state() { # <ok|blocked> → 최대 40s 폴링
	local want="$1" i
	for i in $(seq 1 20); do
		if ptcp; then [ "$want" = ok ] && return 0; else [ "$want" = blocked ] && return 0; fi
		sleep 2
	done
	return 1
}
wait_state blocked && pass "다른 namespace pod → compiler:80 연결 실패" || fail "다른 namespace pod 가 compiler:80 에 연결됨 (정책 미강제?)"
k -n "$NS" delete netpol compiler-ingress compiler-egress --ignore-not-found >/dev/null 2>&1
wait_state ok && pass "대조군: 정책 삭제 시 같은 pod 연결 성공 (정책이 실제로 차단 중이었음)" || fail "대조군: 정책을 지워도 연결 실패 (실패 원인이 정책이 아님)"
restore_policies
wait_state blocked && pass "정책 복구 후 다시 연결 실패" || fail "정책 복구 후에도 연결됨"
n_np="$(k -n "$NS" get netpol -o name 2>/dev/null | grep -c 'compiler-')"
[ "$n_np" = "2" ] && pass "NetworkPolicy compiler-ingress/egress 존재" || fail "NetworkPolicy 개수=${n_np}"
body="$(post 'fn main() { println!("hello"); }')"
v="$(printf '%s' "$body" | pyj "d['status']")"
[ "$v" = "success" ] && pass "backend → compiler 호출 성공 (/api/execute success)" || fail "/api/execute status='${v}'"

# ---- 5. readOnlyRootFilesystem 에서 compile 정상 ----
ro="$(k -n "$NS" get deploy compiler -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}/{.spec.template.spec.enableServiceLinks}/{.spec.template.spec.automountServiceAccountToken}')"
[ "$ro" = "true/false/false" ] && pass "pod 설정 readOnlyRootFilesystem/enableServiceLinks/automountServiceAccountToken = $ro" || fail "pod 설정='${ro}' (기대 true/false/false)"
CPOD="$(k -n "$NS" get pod -l app=compiler -o jsonpath='{.items[0].metadata.name}')"
k -n "$NS" port-forward "pod/$CPOD" 18082:8080 >"$TMP/pf.log" 2>&1 &
PF=$!
for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/18082) 2>/dev/null && break; sleep 1; done
printf 'fn main() { println!("hi"); }' | curl -s --max-time 60 -o "$TMP/o.wasm" -X POST -H 'Content-Type: text/plain' --data-binary @- http://127.0.0.1:18082/compile
kill "$PF" 2>/dev/null
magic="$(head -c4 "$TMP/o.wasm" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
[ "$magic" = "0061736d" ] && pass "compile 응답 \\0asm (readOnlyRootFilesystem 상태)" || fail "compile 응답 앞 4바이트='${magic}'"

# ---- 6. 단위 테스트 + 회귀 ----
if "$ROOT/scripts/with-docker.sh" docker run --rm -v "$ROOT/backend:/src" -w /src -e GOTOOLCHAIN=local \
	golang:1.27.3-trixie go test -count=1 ./cmd/compiler/... ./internal/... >"$TMP/gotest.log" 2>&1; then
	pass "go test (deny-list, env 목록 포함) 통과"
else fail "go test 실패: $(tail -20 "$TMP/gotest.log")"; fi
if bash scripts/verify/m2-01.sh >"$TMP/m201.log" 2>&1; then pass "m2-01.sh 통과"; else fail "m2-01.sh 실패: $(tail -5 "$TMP/m201.log")"; fi
if make --no-print-directory verify-m1 >"$TMP/m1.log" 2>&1; then pass "make verify-m1 통과"; else fail "make verify-m1 실패: $(tail -5 "$TMP/m1.log")"; fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS (m2-02)"; exit 0; fi
echo "FAILED: ${fails}건 (m2-02)" >&2
exit 1
