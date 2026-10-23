#!/usr/bin/env bash
# F-M6-01 readme 정적 검증. README.md 가 subject VI / PRD 11장 형식을 지키고,
# 적힌 make 타겟·상대 경로·버전이 저장소의 실제 값과 일치하는지만 본다 (클러스터 불필요).
# 판정은 Debian VM(Linux, GNU grep -P)에서 한다.
set -u

if [ "$(uname -s)" != "Linux" ]; then
	echo "FAIL: Linux(Debian VM)에서만 실행할 수 있습니다 (현재: $(uname -s)). VM에서 실행하세요." >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
README="$ROOT/README.md"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
info() { printf 'INFO: %s\n' "$1"; }

if [ ! -f "$README" ]; then
	fail "README.md 없음"
	echo "m6-01: FAILED ($fails)" >&2
	exit 1
fi

# ---- 1. 첫 줄 (이탤릭, login 은 【login】 또는 login 목록) ----
first="$(head -n 1 "$README")"
re='^\*This project has been created as part of the 42 curriculum by (【login】|[a-z0-9_-]+(, [a-z0-9_-]+)*)\.\*$'
if [[ "$first" =~ $re ]]; then
	pass "첫 줄이 subject 문구와 일치 (이탤릭)"
else
	fail "첫 줄 불일치: $first"
fi

# ---- 2. 필수 섹션 ----
for s in Description Instructions Resources; do
	if grep -q "^## $s\$" "$README"; then pass "## $s 존재"; else fail "## $s 없음"; fi
done
if awk '/^## /{in_r = ($0 == "## Resources")} in_r && /^### Use of AI$/{found=1} END{exit !found}' "$README"; then
	pass "Resources 안에 '### Use of AI' 존재"
else
	fail "Resources 안에 '### Use of AI' 없음"
fi

# ---- 3. make 타겟 ----
targets="$(grep -oE '^[a-zA-Z][a-zA-Z0-9_-]*:' Makefile | tr -d ':' | sort -u)"
used="$( { grep -oP '`\s*(\$ )?make\s+\K[^`&|;]*' "$README"; grep -oP '^\s*(\$ )?make\s+\K[^&|;#]*' "$README"; } 2>/dev/null \
	| tr ' ' '\n' | grep -E '^[a-z][a-z0-9_-]*$' | sort -u)"
n_t=0
for t in $used; do
	n_t=$((n_t + 1))
	if grep -qx "$t" <<<"$targets"; then pass "make $t 가 Makefile 에 존재"; else fail "make $t 가 Makefile 에 없음"; fi
done
[ "$n_t" -gt 0 ] || fail "README 에 make 타겟 언급이 없음"
# 아직 구현되지 않은 타겟(TODO 출력)은 README 에 쓰지 않는다
for t in $used; do
	if grep -A1 "^$t:" Makefile | grep -q 'TODO'; then fail "make $t 는 아직 TODO 타겟인데 README 에 있음"; fi
done

# ---- 4. 상대 경로 링크 / 저장소 경로 ----
paths="$( { grep -oP '\]\(\K[^)]+' "$README"; \
	grep -oP '`\K(backend|frontend|k8s|dashboards|scripts|docs)/[A-Za-z0-9_./-]*(?=`)' "$README"; } 2>/dev/null \
	| grep -vE '^(https?:|mailto:|#)' | sed 's/#.*$//' | sort -u)"
n_p=0
for p in $paths; do
	[ -n "$p" ] || continue
	n_p=$((n_p + 1))
	if [ -e "$ROOT/$p" ]; then pass "경로 존재: $p"; else fail "경로 없음: $p"; fi
done
[ "$n_p" -gt 0 ] || fail "README 에 저장소 경로/링크가 없음"

# ---- 5. 버전 ----
known="$( { awk '!/^[[:space:]]*(#|$)/{print $2}' images.txt | sed 's/.*://'; \
	grep -E '^[A-Z0-9_]+_VERSION[[:space:]]*:=|^K3S_IMAGE[[:space:]]*:=' Makefile | sed -E 's/^[^=]*=[[:space:]]*//; s/.*://'; \
	grep -E '^DOCKER_VERSION_STR' Makefile | sed -E 's/^[^=]*=[[:space:]]*//'; \
	grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' backend/go.mod; \
	grep -oE '"[~^]?[0-9]+\.[0-9]+\.[0-9]+"' frontend/package.json | tr -d '"~^'; } | sort -u)"
# 이미지 참조(repo/name:tag)는 images.txt 에 그대로 있어야 한다
for ref in $(grep -oP '`\K[a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+(?=`)' "$README" | sort -u); do
	if awk '!/^[[:space:]]*(#|$)/{print $2}' images.txt | grep -qxF "$ref"; then pass "이미지 $ref 가 images.txt 와 일치"
	else fail "이미지 $ref 가 images.txt 에 없음"; fi
done
# X.Y.Z 형태 버전 번호는 images.txt / Makefile 고정 값에 있어야 한다 (v 접두는 무시)
# (URL 안의 버전은 문서 주소의 일부라 제외한다)
for v in $(sed -E 's#https?://[^ )>`]*##g' "$README" | grep -oP '(?<![\w.])v?\d+\.\d+\.\d+(?!\.?\d)' | sort -u); do
	bare="${v#v}"
	if grep -qE "(^|[^0-9.])v?${bare//./\\.}([^0-9.]|\$)" <<<"$known"; then pass "버전 $v 가 고정 값과 일치"
	else fail "버전 $v 가 images.txt / Makefile 고정 값에 없음"; fi
done

# ---- 6. 남은 자리표시 (FAIL 아님) ----
ph="$(grep -o '【[^】]*】' "$README" | sort | uniq -c)"
if [ -n "$ph" ]; then
	info "남은 자리표시:"
	printf '%s\n' "$ph" | sed 's/^/INFO:   /'
else
	info "남은 자리표시 없음"
fi

if [ "$fails" -eq 0 ]; then echo "m6-01: ALL PASS"; else echo "m6-01: FAILED ($fails)" >&2; exit 1; fi
