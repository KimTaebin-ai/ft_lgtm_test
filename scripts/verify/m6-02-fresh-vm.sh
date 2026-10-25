#!/usr/bin/env bash
# F-M6-02 fresh-vm 정적 검증. 새 VM에서 make 한 번으로 동작하기 위한 조건(폰트, sudo 순서, 대기 상한,
# fclean/re, 공개 gateway 링크, 출제자 확인 문구, 재부팅 내성 설정)을 본다. 재부팅 자체는 scripts/tools/reboot-check.sh.
# 판정은 Debian VM(Linux)에서 한다.
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

# 1. 한글 폰트
if [ "$(dpkg-query -W -f='${Status}' fonts-noto-cjk 2>/dev/null)" = "install ok installed" ]; then
	pass "fonts-noto-cjk 설치됨"
else fail "fonts-noto-cjk 설치 안 됨"; fi
grep -q 'fonts-noto-cjk' scripts/setup/install.sh && pass "install.sh 가 fonts-noto-cjk 설치" || fail "install.sh 에 fonts-noto-cjk 없음"

# 2. fclean / re 구현됨 (TODO 아님)
for t in fclean re; do
	if grep -A2 "^$t:" Makefile | grep -q 'TODO'; then fail "make $t 가 아직 TODO"; else pass "make $t 구현됨"; fi
done

# 3. all 의 prerequisite 순서: sudo-auth 가 맨 앞, hosts 는 install 다음이고 cluster 앞
prereq="$(sed -n 's/^all:[[:space:]]*//p' Makefile)"
pos() { printf '%s\n' "$prereq" | tr ' ' '\n' | grep -nx "$1" | cut -d: -f1; }
p_sudo="$(pos sudo-auth)"; p_inst="$(pos install)"; p_hosts="$(pos hosts)"; p_cl="$(pos cluster)"; p_dep="$(pos deploy)"
if [ "${p_sudo:-0}" = 1 ] && [ -n "$p_inst" ] && [ -n "$p_hosts" ] && [ -n "$p_cl" ] && [ -n "$p_dep" ] \
	&& [ "$p_inst" -lt "$p_hosts" ] && [ "$p_hosts" -lt "$p_cl" ]; then
	pass "all: $prereq"
else fail "all prerequisite 순서: '$prereq' (기대: sudo-auth install hosts cluster build deploy)"; fi

# 4. 클러스터 대기 상한 600s
n600="$(grep -cE '600' scripts/setup/cluster.sh)"
if grep -qE '^WAIT_TIMEOUT=600$' scripts/setup/cluster.sh && ! grep -qE '\b(120|180)s?\b' scripts/setup/cluster.sh; then
	pass "cluster.sh 대기 상한 600s (600 언급 $n600 곳, 120/180 없음)"
else fail "cluster.sh 대기 상한이 600s 가 아님 (WAIT_TIMEOUT=600 없음 또는 120/180 남음)"; fi

# 5. FE 공개 gateway 링크
fe=frontend/src/ResultView.tsx
if grep -qF "'https://inbrowser.link/ipfs/'" "$fe" && ! grep -qF 'ipfs.io/ipfs/' "$fe"; then
	pass "ResultView 공개 링크 inbrowser.link (ipfs.io 없음)"
else fail "ResultView 공개 링크가 inbrowser.link 가 아니거나 ipfs.io/ipfs/ 가 남음"; fi

# 6. 출제자 확인 문구 (정확 일치)
QUOTE='Subject authors confirmed (world_beta, 2026-10-23) that explaining a campus network limitation is acceptable, and that a service worker gateway such as inbrowser.link or any public gateway may be used instead of ipfs.io.'
grep -qF -- "$QUOTE" README.md && pass "README 출제자 확인 문구" || fail "README 에 출제자 확인 문구가 정확히 없음"

# 7. make -n fclean / re
for t in fclean re; do
	make -n "$t" >/dev/null 2>&1 && pass "make -n $t" || fail "make -n $t 실패"
done

# 8. VERIFY_ALL: 맨 앞 m0-01, m0-02, m6-02 포함
va="$(var VERIFY_ALL)"
first2="$(printf '%s\n' "$va" | tr -s ' ' '\n' | grep . | head -2 | xargs)"
[ "$first2" = "m0-01-skeleton-install m0-02-cluster-ingress-hosts" ] && pass "VERIFY_ALL 맨 앞: $first2" \
	|| fail "VERIFY_ALL 맨 앞 두 항목: '$first2'"
printf '%s\n' "$va" | tr -s ' ' '\n' | grep -qx 'm6-02-fresh-vm' && pass "VERIFY_ALL 에 m6-02-fresh-vm" || fail "VERIFY_ALL 에 m6-02-fresh-vm 없음"

# 9. 재부팅 내성: docker 부팅 시 시작, install.sh skip 조건에 is-enabled, k3d 노드 컨테이너 restart policy
systemctl is-enabled --quiet docker && pass "docker.service enabled" || fail "docker.service 가 enabled 가 아님"
grep -q 'systemctl is-enabled --quiet docker' scripts/setup/install.sh && pass "install.sh docker_ok 가 is-enabled 확인" \
	|| fail "install.sh docker_ok 에 is-enabled 확인 없음"
CLUSTER_NAME="$(var CLUSTER_NAME)"
for c in "k3d-${CLUSTER_NAME}-server-0" "k3d-${CLUSTER_NAME}-serverlb"; do
	rp="$(scripts/lib/with-docker.sh docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)"
	case "$rp" in
		always | unless-stopped) pass "$c restart policy $rp" ;;
		*) fail "$c restart policy '${rp:-없음}' (always/unless-stopped 아님)" ;;
	esac
done
[ -x scripts/tools/reboot-check.sh ] && pass "scripts/tools/reboot-check.sh 있음" || fail "scripts/tools/reboot-check.sh 없음"

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
