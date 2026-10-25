#!/usr/bin/env bash
# comment-cleanup 정적 검증 (클러스터 불필요). 판정은 Debian VM(Linux)에서 한다.
#  (a) origin/main 대비 주석/빈 줄이 아닌 +/- 줄 목록 (사람이 확인한다. 판정하지 않음)
#  (b) origin/main 대비 ConfigMap data 블록(`key: |`) 내용 변경 0
#  (c) 주석과 dashboard description 에 피처 ID / PRD 요구사항 번호 / 개발 기록 참조 / 날짜가 남지 않음
# (a)(b)는 .git 이 있고 origin/main 과 차이가 있을 때만 돈다 (VM 의 rsync 사본에는 .git 이 없어 SKIP).
# CHECK_ROOT=<dir> 이면 (c)만 그 디렉토리에서 센다 (정리 전 개수 비교용).
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
info() { printf 'INFO: %s\n' "$1"; }

SCOPE=(backend frontend/src frontend/Dockerfile frontend/nginx.conf k8s scripts dashboards Makefile)

# ---- (a)(b) origin/main 대비 diff ----
if [ -n "${CHECK_ROOT:-}" ]; then
	info "(a)(b) SKIP: CHECK_ROOT 지정"
elif ! git rev-parse --verify -q origin/main >/dev/null 2>&1; then
	info "(a)(b) SKIP: git 저장소 또는 origin/main 없음"
elif git diff --quiet origin/main -- "${SCOPE[@]}" ":!$SELF"; then
	info "(a)(b) SKIP: origin/main 과 diff 없음"
else
	# (a) 주석(#, //, /*, *)도 빈 줄도 아닌 변경 줄. 코드 끝에 주석이 붙은 줄도 여기 나온다
	echo "--- (a) 주석/빈 줄이 아닌 +/- 줄 (사람이 확인):"
	git diff -U0 origin/main -- "${SCOPE[@]}" ":!$SELF" |
		awk '/^\+\+\+ /{f=substr($0,7); next} /^--- /{next} /^[+-]/{
			l=substr($0,2); if (l ~ /^[[:space:]]*$/ || l ~ /^[[:space:]]*(#|\/\/|\/\*|\*)/) next
			print f": "$0 }'
	echo "--- (a) 끝"

	# (b) data 블록: `<key>: |` 다음부터 들여쓰기가 key 보다 깊은 줄
	blocks() {
		awk '{ ind=match($0,/[^ ]/)-1
			if (inb && ($0 ~ /^[[:space:]]*$/ || ind > kind)) { print; next }
			inb=0
			if ($0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+: \|-?[[:space:]]*$/) { inb=1; kind=ind; print "## " $0 } }'
	}
	for f in $(git diff --name-only origin/main -- k8s); do
		if [ -f "$f" ] && git cat-file -e "origin/main:$f" 2>/dev/null; then
			if diff <(git show "origin/main:$f" | blocks) <(blocks <"$f") >/dev/null; then
				pass "(b) $f ConfigMap data 블록 변경 없음"
			else
				fail "(b) $f ConfigMap data 블록이 바뀜: $(diff <(git show "origin/main:$f" | blocks) <(blocks <"$f") | head -5)"
			fi
		fi
	done
fi

# ---- (c) 잔존 패턴 ----
CROOT="${CHECK_ROOT:-$ROOT}"
python3 -I - "$CROOT" "$SELF" "${SCOPE[@]}" <<'PY'
import os, re, sys
root, self_path, scope = sys.argv[1], sys.argv[2], sys.argv[3:]
PATS = {
    "피처 ID": re.compile(r"F-M\d+-\d+"),
    "PRD 번호": re.compile(r"\bPRD\b|\b(SEC|TR|IP|INF|FE|BE)-\d+"),
    "개발 기록 참조": re.compile(r"HANDOFF|spike|타임라인|검증에서|verify에서|실측은"),
    "날짜": re.compile(r"20\d\d-\d\d-\d\d"),
}
# 남기는 것: 스크립트가 실제로 HANDOFF.md 를 읽거나 경로로 다루는 곳, 스크립트 안 진단 루프 이름
ALLOW = [
    ("scripts/verify/m3-03-external-gateway.sh", "HANDOFF"),
    ("scripts/verify/m6-05-repo-layout.sh", "HANDOFF"),
    ("scripts/verify/m6-04-stability.sh", "타임라인"),
]
SKIP_EXT = (".sum", ".svg", ".png", ".lock", ".css", ".txt", ".mod")
files = []
for s in scope:
    p = os.path.join(root, s)
    if os.path.isfile(p):
        files.append(s)
    for d, dirs, fs in os.walk(p):
        dirs[:] = [x for x in dirs if x != "node_modules"]
        files += [os.path.relpath(os.path.join(d, f), root) for f in fs]
block = re.compile(r"^(\s*)[A-Za-z0-9_.-]+: \|-?\s*$")
desc = re.compile(r'"description":\s*"(.*)"')
counts = {k: 0 for k in PATS}
hits = []
for f in sorted(set(files)):
    if f == self_path or f.endswith(SKIP_EXT) or os.path.basename(f) == ".dockerignore":
        continue
    slash = f.endswith((".go", ".ts", ".tsx"))
    kind = None  # ConfigMap data 블록 들여쓰기 (블록 안 주석은 설정 내용이라 검사하지 않는다)
    for n, line in enumerate(open(os.path.join(root, f), encoding="utf-8"), 1):
        if f.endswith((".yaml", ".yml")):
            ind = len(line) - len(line.lstrip(" "))
            if kind is not None and (not line.strip() or ind > kind):
                continue
            kind = None
            m = block.match(line)
            if m:
                kind = len(m.group(1))
                continue
        if f.endswith(".json"):
            m = desc.search(line)
            text = m.group(1) if m else ""
        else:
            m = re.search(r"(^|\s)//" if slash else r"(^|\s)#(?!!)", line)
            text = line[m.start():] if m else ""
        if not text:
            continue
        for k, p in PATS.items():
            if p.search(text) and not any(f == af and re.search(ap, text) for af, ap in ALLOW):
                counts[k] += 1
                hits.append("%s:%d [%s] %s" % (f, n, k, text.strip()[:140]))
for k, v in counts.items():
    print("COUNT: %s %d" % (k, v))
for h in hits:
    print("HIT: " + h)
sys.exit(1 if hits else 0)
PY
[ $? -eq 0 ] && pass "(c) 주석/description 잔존 패턴 0건" || fail "(c) 잔존 패턴 있음 (HIT 줄 참고)"

if [ "$fails" -ne 0 ]; then echo "RESULT: $fails 건 실패" >&2; exit 1; fi
echo "RESULT: 모두 통과"
