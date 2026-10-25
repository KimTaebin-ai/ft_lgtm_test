#!/usr/bin/env bash
# external-gateway 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build && make deploy 가 끝난 상태 (kubo-0 Ready).
# public gateway 성공 여부는 네트워크(NAT)에 따라 다르므로 통과 조건에 넣지 않는다.
# 검사하는 것: make ipfs-check 가 끝까지 실행되고 정해진 형식으로 출력하는가, 테스트 CID 가 로컬 gateway 에서 열리는가, 결과가 HANDOFF 에 있는가.
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
OUT="$TMP/ipfs-check.out"

# ---- 1. make ipfs-check 가 끝까지 실행 (gateway 실패여도 exit 0) ----
t0=$SECONDS
make --no-print-directory ipfs-check >"$OUT" 2>&1
rc=$?
info "make ipfs-check exit=$rc ($((SECONDS - t0))s)"
sed 's/^/  | /' "$OUT"
[ "$rc" = "0" ] && pass "make ipfs-check exit 0" || fail "make ipfs-check exit=$rc"

# ---- 2. 단계별 결과 형식 ----
for s in S1 S2 S3 S4 S5 S6 S7 S8 S9; do
	grep -Eq "^\[ipfs-check\] $s (PASS|FAIL|INFO|SKIP) " "$OUT" && pass "단계 $s 결과 줄" || fail "단계 $s 결과 줄 없음 (형식: [ipfs-check] $s PASS|FAIL|INFO|SKIP <내용>)"
done
n="$(grep -Ec '^\[ipfs-check\] GATEWAY [^ ]+ [0-9]{3} [0-9.]+s (ok|mismatch|fail|policy|noconn) ' "$OUT")"
[ "$n" -ge 3 ] && pass "GATEWAY 결과 ${n}줄 (host / code / 시간 / 판정)" || fail "GATEWAY 결과 줄 ${n}개 (3개 이상 기대)"
sm="$(grep -E '^\[ipfs-check\] SUMMARY first_blocked=(vm-4001|utm|router|internet|none|unknown) reason=.+' "$OUT")"
[ -n "$sm" ] && pass "SUMMARY: ${sm#\[ipfs-check\] SUMMARY }" || fail "SUMMARY 줄 없음 (first_blocked=vm-4001|utm|router|internet|none|unknown reason=...)"

# ---- 3. 테스트 CID 가 로컬 gateway 에서 열림 ----
CID="$(sed -n 's/^\[ipfs-check\] CID \([A-Za-z0-9]*\)$/\1/p' "$OUT" | head -1)"
if [ -z "$CID" ]; then
	fail "출력에 '[ipfs-check] CID <cid>' 줄 없음"
else
	code="$(curl -s --max-time 15 --resolve ipfs.lgtm.local:80:127.0.0.1 -o /dev/null -w '%{http_code}' "http://ipfs.lgtm.local/ipfs/$CID")"
	[ "$code" = "200" ] && pass "로컬 gateway ipfs.lgtm.local/ipfs/$CID 200" || fail "로컬 gateway code=${code}"
	size="$(curl -s --max-time 15 --resolve ipfs.lgtm.local:80:127.0.0.1 "http://ipfs.lgtm.local/ipfs/$CID" | wc -c)"
	{ [ "$size" -gt 0 ] && [ "$size" -lt 10240 ]; } && pass "테스트 파일 크기 ${size}B (< 10kB, relay 실측 조건)" || fail "테스트 파일 크기 ${size}B"
fi

# ---- 4. 진단 결과가 HANDOFF 에 기록됨 ----
grep -q '^## F-M3-03 ' docs/HANDOFF.md && pass "HANDOFF F-M3-03 블록" || fail "docs/HANDOFF.md 에 '## F-M3-03 ' 블록 없음"
awk '/^## F-M3-03 /{f=1;next} /^## /{f=0} f' docs/HANDOFF.md | grep -q 'first_blocked=' && pass "HANDOFF 에 진단 결과(first_blocked=) 기록" || fail "HANDOFF F-M3-03 블록에 first_blocked= 기록 없음"

if [ "$fails" -eq 0 ]; then
	echo "m3-03: ALL PASS"
else
	echo "m3-03: ${fails} FAIL" >&2
	exit 1
fi
