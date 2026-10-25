#!/usr/bin/env bash
# image-prefetch 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make clean && make 가 끝난 상태. (c) events 검사는 cold 실행(make clean && make) 직후에 해야 의미가 있다
#       (events TTL 1h. cold = docker host 에서 workload + infra 이미지를 rmi 한 뒤의 실행).
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

D="$ROOT/scripts/lib/with-docker.sh"
CLUSTER_NAME="$(var CLUSTER_NAME)"
CTX="k3d-${CLUSTER_NAME:-lgtm}"
NODE="k3d-${CLUSTER_NAME:-lgtm}-server-0"
k() { kubectl --context "$CTX" "$@"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# images_of <role|all> : k8s/images.txt 에서 이미지 이름만
images_of() {
	awk -v r="$1" '!/^[[:space:]]*(#|$)/ && (r == "all" || $1 == r) {print $2}' "$ROOT/k8s/images.txt"
}

# ---- 1. 목록 파일과 docker host ----
if [ ! -f "$ROOT/k8s/images.txt" ]; then
	fail "k8s/images.txt 없음"
	echo "FAIL: k8s/images.txt 가 없어 이후 검사를 할 수 없습니다" >&2
	exit 1
fi
n_all="$(images_of all | wc -l)"
[ "$n_all" -gt 0 ] && pass "k8s/images.txt 항목 ${n_all}개" || fail "k8s/images.txt 가 비어 있음"
for r in workload build infra; do
	[ "$(images_of "$r" | wc -l)" -gt 0 ] && pass "k8s/images.txt role=$r 있음" || fail "k8s/images.txt 에 role=$r 항목 없음"
done
images_of all | grep -qE ':latest$' && fail "k8s/images.txt 에 :latest 태그가 있음" || pass "k8s/images.txt 에 :latest 없음"

missing=""
while read -r img; do
	"$D" docker image inspect "$img" >/dev/null 2>&1 || missing+=" $img"
done < <(images_of all)
[ -z "$missing" ] && pass "목록의 모든 이미지가 docker host 에 있음" || fail "docker host 에 없는 이미지:$missing"

# ---- 2. k3d 노드 containerd 에 workload 이미지 ----
node_imgs="$("$D" docker exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null)"
if [ -z "$node_imgs" ]; then
	fail "노드 $NODE 의 ctr images ls 결과가 비어 있음 (클러스터 없음?)"
else
	missing=""
	while read -r img; do
		# docker.io 짧은 이름은 노드에서 docker.io/ 접두사 (+ library/) 로 정규화될 수 있다
		printf '%s\n' "$node_imgs" | grep -qxE "(docker\.io/)?(library/)?$(printf '%s' "$img" | sed 's/[.[\*^$/]/\\&/g')" || missing+=" $img"
	done < <(images_of workload)
	[ -z "$missing" ] && pass "workload 이미지가 모두 k3d 노드 containerd 에 있음" || fail "노드에 없는 workload 이미지:$missing"
fi

# ---- 3. 목록 / manifest 불일치 0 ----
if out="$(bash "$ROOT/scripts/images/check-images.sh" 2>&1)"; then
	pass "check-images.sh 불일치 0"
else
	fail "check-images.sh 실패: $(printf '%s' "$out" | head -5 | tr '\n' ' ')"
fi

# ---- 4. events: workload 이미지 실제 pull 없음 (cold 실행 직후 기준) ----
ev="$(k get events -A -o jsonpath='{range .items[*]}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null)"
if [ -z "$ev" ]; then
	fail "kubectl get events -A 결과가 비어 있음"
else
	bad=""
	while read -r img; do
		printf '%s\n' "$ev" | grep -E "^(Pulling|Pulled)	" | grep -F "\"$img\"" | grep -vq "already present" && bad+=" $img"
	done < <(images_of workload)
	[ -z "$bad" ] && pass "events 에 workload 이미지 실제 pull(Pulling/Pulled) 없음" || fail "workload 이미지가 노드에서 pull 됨:$bad"
	present="$(printf '%s\n' "$ev" | grep -c 'already present on machine')"
	[ "$present" -gt 0 ] && pass "events 에 'already present on machine' ${present}건" || fail "'already present on machine' 이벤트 없음"
fi

# ---- 5. imagePullPolicy ----
# k3s 시스템 deploy 는 대상 아님 (lgtm 이 만든 ns 만)
bad="$(for ns in observability ipfs lgtm; do
	k -n "$ns" get deploy,statefulset -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.name}{"="}{.imagePullPolicy}{"\n"}{end}{end}' 2>/dev/null
done | grep -vE '^$' | grep -v '=IfNotPresent$' || true)"
[ -z "$bad" ] && pass "observability/ipfs/lgtm 모든 컨테이너 imagePullPolicy=IfNotPresent" || fail "IfNotPresent 아님: $bad"

# ---- 6. 재시도 단위 테스트 (docker 주입) ----
FAKE="$TMP/fake-docker.sh"
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
# fake docker: "image inspect" 는 FAKE_PRESENT=1 이면 성공, "pull" 은 FAKE_OK_AT 번째 호출부터 성공 (0 이면 영영 실패)
case "$1 $2" in
	"image inspect") [ "${FAKE_PRESENT:-0}" = 1 ]; exit $? ;;
esac
if [ "$1" = pull ]; then
	n=$(($(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE_COUNT"
	[ "${FAKE_OK_AT:-0}" -gt 0 ] && [ "$n" -ge "$FAKE_OK_AT" ] && exit 0
	echo "fake pull fail #$n" >&2; exit 1
fi
exit 0
EOF
chmod +x "$FAKE"
printf 'workload example.invalid/fake/img:1.0\n' >"$TMP/images.txt"
export IMAGES_FILE="$TMP/images.txt" PREFETCH_DOCKER="$FAKE" PREFETCH_SLEEP=true FAKE_COUNT="$TMP/count"

run_pf() { bash "$ROOT/scripts/images/prefetch-images.sh" workload >"$TMP/out" 2>"$TMP/err"; }

echo 0 >"$FAKE_COUNT"
FAKE_OK_AT=3 PREFETCH_RETRIES=5 run_pf; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$FAKE_COUNT")" -eq 3 ] && pass "2번 실패 후 3번째 성공 → exit 0 (pull 3회)" || fail "N번째 성공 테스트: rc=$rc pull=$(cat "$FAKE_COUNT")"

echo 0 >"$FAKE_COUNT"
FAKE_OK_AT=0 PREFETCH_RETRIES=3 run_pf; rc=$?
if [ "$rc" -eq 1 ] && [ "$(cat "$FAKE_COUNT")" -eq 3 ] && grep -qF 'example.invalid/fake/img:1.0' "$TMP/err"; then
	pass "전부 실패 → exit 1, pull 3회, stderr 에 이미지 이름"
else
	fail "전부 실패 테스트: rc=$rc pull=$(cat "$FAKE_COUNT") err=$(tr '\n' ' ' <"$TMP/err")"
fi

echo 0 >"$FAKE_COUNT"
FAKE_PRESENT=1 FAKE_OK_AT=0 PREFETCH_RETRIES=3 run_pf; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$FAKE_COUNT")" -eq 0 ] && pass "이미 있으면 pull 호출 0 (skip)" || fail "skip 테스트: rc=$rc pull=$(cat "$FAKE_COUNT")"
unset IMAGES_FILE PREFETCH_DOCKER PREFETCH_SLEEP FAKE_COUNT

# ---- 결과 ----
if [ "$fails" -gt 0 ]; then
	echo "FAIL: m6-03 검증 실패 ${fails}건" >&2
	exit 1
fi
echo "m6-03: ALL PASS"
