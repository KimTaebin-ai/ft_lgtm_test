#!/usr/bin/env bash
# repo-layout 정적 검증 (클러스터 불필요).
# 루트 파일 목록, .gitkeep / k8s/dummy 부재, 옛 경로 문자열 0건, Makefile 이 참조하는 스크립트 존재를 본다.
# 판정은 Debian VM(Linux, GNU grep)에서 한다.
set -u

if [ "$(uname -s)" != "Linux" ]; then
	echo "FAIL: Linux(Debian VM)에서만 실행할 수 있습니다 (현재: $(uname -s)). VM에서 실행하세요." >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
SELF="scripts/verify/$(basename "${BASH_SOURCE[0]}")"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# ---- 1. 루트 파일 목록 ----
want=".gitignore CLAUDE.md Makefile README.md"
got="$(find . -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort | xargs)"
[ "$got" = "$want" ] && pass "루트 파일: $got" || fail "루트 파일: 기대 '$want' / 실제 '$got'"

# ---- 2. .gitkeep 0개 ----
keeps="$(find . -name .gitkeep -not -path './.git/*' -not -path '*/node_modules/*' | xargs)"
[ -z "$keeps" ] && pass ".gitkeep 0개" || fail ".gitkeep 남아 있음: $keeps"

# ---- 3. k8s/dummy 없음 ----
[ ! -e k8s/dummy ] && pass "k8s/dummy 없음" || fail "k8s/dummy 가 남아 있음"

# ---- 4. 옛 경로 문자열 0건 (docs/HANDOFF.md 와 이 스크립트 제외) ----
old_scripts='install|cluster|hosts|build|build-frontend|image-tag|with-docker|prefetch-images|import-images|check-images|wait-backend|wait-ingress|wait-dashboards|load|ipfs-check'
patterns=(
	"scripts/($old_scripts)\.sh"
	'scripts/verify/m[0-9]-[0-9]{2}\.sh'
	'(^|[^/[:alnum:]_])(images\.txt|HANDOFF\.md)'
	'\$ROOT/(images\.txt|HANDOFF\.md)'
	'k8s/dummy'
)
targets=(Makefile README.md CLAUDE.md scripts backend k8s frontend/Dockerfile frontend/.dockerignore)
for re in "${patterns[@]}"; do
	hits="$(grep -rnE --exclude-dir=node_modules -e "$re" "${targets[@]}" 2>/dev/null | grep -v "^$SELF:")"
	# m3-01 / m4-02 의 dummy 부재 검사는 유지한다
	[ "$re" = 'k8s/dummy' ] && hits="$(printf '%s\n' "$hits" | grep -vE '^scripts/verify/m(3-01|4-02)-[a-z-]+\.sh:' | grep .)"
	[ -z "$hits" ] && pass "옛 경로 0건: $re" || fail "옛 경로 남음 ($re):"$'\n'"$hits"
done

# ---- 5. Makefile 이 참조하는 스크립트가 실제로 존재 ----
refs="$(grep -oE 'scripts/[A-Za-z0-9_/.-]+\.sh' Makefile | sort -u)"
[ -n "$refs" ] || fail "Makefile 에 scripts/*.sh 참조가 없음"
for f in $refs; do
	[ -f "$f" ] && pass "Makefile 참조 존재: $f" || fail "Makefile 참조 없음: $f"
done
for s in $(make --no-print-directory -s print-VERIFY_ALL); do
	[ -f "scripts/verify/$s.sh" ] && pass "VERIFY_ALL: scripts/verify/$s.sh" || fail "VERIFY_ALL 스크립트 없음: scripts/verify/$s.sh"
done

# ---- 6. 이동한 파일 ----
for f in k8s/images.txt docs/HANDOFF.md; do
	[ -f "$f" ] && pass "file $f" || fail "file $f 없음"
done

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
