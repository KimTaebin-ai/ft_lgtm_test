#!/usr/bin/env bash
# F-M0-01 skeleton-install 검증. Debian VM(Linux)에서만 실행한다.
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

# 1. 바이너리 존재 + 고정 버전 일치
check_ver() { # name expected actual
	if [ -n "$3" ] && [ "$3" = "$2" ]; then pass "$1 $2"; else fail "$1: 기대 '$2' / 실제 '${3:-없음}'"; fi
}
check_ver kubectl "$(var KUBECTL_VERSION)" "$(kubectl version --client 2>/dev/null | sed -n 's/^Client Version: //p')"
check_ver helm "$(var HELM_VERSION)" "$(helm version --template '{{.Version}}' 2>/dev/null)"
check_ver k3d "$(var K3D_VERSION)" "$(k3d version 2>/dev/null | sed -n '1s/^k3d version //p')"
dv="$(var DOCKER_VERSION_STR)"
check_ver docker-ce "$dv" "$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null)"
check_ver docker-ce-cli "$dv" "$(dpkg-query -W -f='${Version}' docker-ce-cli 2>/dev/null)"
installed() { [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]; }
installed docker-buildx-plugin && pass "docker-buildx-plugin 설치됨" || fail "docker-buildx-plugin 없음"
installed docker-compose-plugin && fail "docker-compose-plugin 이 설치되어 있음" || pass "docker-compose-plugin 없음"
echo "INFO: k3d 기본 k3s / 고정 K3S_IMAGE: $(k3d version 2>/dev/null | sed -n 's/^k3s version //p') / $(var K3S_IMAGE)"

# 2. docker daemon + 래퍼
systemctl is-active --quiet docker && pass "docker daemon active" || fail "docker daemon not active"
scripts/lib/with-docker.sh docker info >/dev/null 2>&1 && pass "래퍼 경유 docker info" || fail "래퍼 경유 docker info 실패"

# 3. sg 경로 quoting
for arg in "it's a b" 'a"b $x `y` \z' "'" ""; do
	got="$(WITH_DOCKER_FORCE_SG=1 scripts/lib/with-docker.sh printf '%s' "$arg" 2>&1)"
	if [ "$got" = "$arg" ]; then pass "FORCE_SG quoting: [$arg]"; else fail "FORCE_SG quoting: 기대 [$arg] / 실제 [$got]"; fi
done

# 4. make install 두 번째 실행은 no-op
out="$(make install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "make install exit 0" || fail "make install exit $rc"
n="$(printf '%s\n' "$out" | grep -c '^\[skip\] ')"
[ "$n" -eq 4 ] && pass "[skip] 4줄" || fail "[skip] 줄 수 $n (기대 4)"
if printf '%s\n' "$out" | grep -Eiq 'apt|curl|wget|download|Get:|Setting up|Unpacking'; then
	fail "재실행 출력에 다운로드/apt 흔적"
else pass "다운로드/apt 흔적 없음"; fi

# 5. 9.1 타겟 존재
for t in all install cluster build deploy hosts status verify ipfs-check clean fclean re; do
	make -n "$t" >/dev/null 2>&1 && pass "make -n $t" || fail "make -n $t"
done

# 6. 스켈레톤
for d in backend frontend k8s dashboards scripts/verify; do
	[ -d "$d" ] && pass "dir $d" || fail "dir $d 없음"
done
for f in .gitignore docs/HANDOFF.md Makefile; do
	[ -f "$f" ] && pass "file $f" || fail "file $f 없음"
done

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
