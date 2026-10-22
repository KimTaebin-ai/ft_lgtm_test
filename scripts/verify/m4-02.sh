#!/usr/bin/env bash
# F-M4-02 result-display 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make (build + deploy) 가 끝난 상태. make deploy/clean 은 호출하지 않는다.
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
HOST="lgtm.local"
D=scripts/with-docker.sh
k() { kubectl --context "$CTX" "$@"; }
lurl() { curl -s --max-time 15 --resolve "$HOST:80:127.0.0.1" "$@"; }

# ---- 1. frontend pod Ready, restart 0 ----
ready="$(k -n lgtm get deploy frontend -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${ready:-0}" -ge 1 ] 2>/dev/null && pass "deploy/frontend Ready (readyReplicas=$ready)" || fail "deploy/frontend Ready 아님 (readyReplicas=${ready:-없음})"
rc="$(k -n lgtm get pods -l app=frontend -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null)"
case "$rc" in
	0 | "0 0") pass "frontend restartCount 0" ;;
	*) fail "frontend restartCount=$rc" ;;
esac

# ---- 2. dummy-lgtm 이 남아 있지 않다 (make 가 본 흐름에서 정리) ----
left="$(k -n dummy get deploy,svc,ingress dummy-lgtm -o name 2>/dev/null)"
[ -z "$left" ] && pass "dummy-lgtm 리소스 없음" || fail "dummy-lgtm 리소스가 남아 있음: $left"
[ ! -e k8s/dummy/lgtm.yaml ] && pass "k8s/dummy/lgtm.yaml 삭제됨" || fail "k8s/dummy/lgtm.yaml 이 남아 있음"

# ---- 3. lgtm.local / 은 앱 ----
body="$(lurl "http://$HOST/")"
case "$body" in *'id="root"'*) pass "lgtm.local / → 앱 HTML (id=\"root\")" ;; *) fail "lgtm.local / 에 id=\"root\" 없음" ;; esac
case "$body" in *lgtm-dummy*) fail "lgtm.local / 이 dummy 텍스트" ;; *) pass "dummy 텍스트 아님" ;; esac

# ---- 4. /api 회귀 ----
code="$(lurl -o /dev/null -w '%{http_code}' "http://$HOST/api/execute")"
[ "$code" = "405" ] && pass "GET /api/execute → 405" || fail "GET /api/execute → $code (405 기대)"
resp="$(lurl -X POST -H 'Content-Type: application/json' -d '{"language":"rust","code":"fn main(){}"}' "http://$HOST/api/execute")"
case "$resp" in *'"status"'*'"trace_id"'* | *'"trace_id"'*'"status"'*) pass "POST /api/execute → status + trace_id 포함 JSON" ;; *) fail "POST /api/execute 응답에 status/trace_id 없음: ${resp:0:120}" ;; esac

# ---- 5. 빌드 산출물 CDN 0건 + src 에 dangerouslySetInnerHTML 없음 ----
img="$(k -n lgtm get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
out="$(mktemp -d)"
trap 'rm -rf "$out"; [ -n "${cid:-}" ] && "$D" docker rm -f "$cid" >/dev/null 2>&1' EXIT
cid="$("$D" docker create "$img" 2>/dev/null)"
if [ -n "$cid" ] && "$D" docker cp "$cid:/usr/share/nginx/html/." "$out/" >/dev/null 2>&1 && [ -f "$out/index.html" ]; then
	cdn='(cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com|cdn\.tailwindcss\.com|code\.jquery\.com|fonts\.googleapis\.com|fonts\.gstatic\.com|ajax\.googleapis\.com|esm\.sh|skypack\.dev)'
	hits="$(grep -rEoh "https?:(//|\\\\/\\\\/)[^\"' )]*$cdn[^\"' )]*" "$out" | sort -u)"
	[ -z "$hits" ] && pass "빌드 산출물 CDN URL 0건" || fail "CDN URL 발견: $(echo "$hits" | head -5 | tr '\n' ' ')"
else
	fail "이미지($img)에서 정적 파일 추출 실패"
fi
if grep -rq 'dangerouslySetInnerHTML' frontend/src --include='*.ts' --include='*.tsx' --exclude='*.test.*'; then
	fail "frontend/src 에 dangerouslySetInnerHTML 사용"
else
	pass "frontend/src 에 dangerouslySetInnerHTML 없음"
fi

# ---- 6. 결과 화면 문구가 번들에 포함 (구현 반영 확인) ----
if [ -d "$out" ] && grep -rqF '실행한 코드와 결과는 IPFS에 영구 공개됩니다' "$out"; then
	pass "번들에 IPFS 공개 안내 문구 포함"
else
	fail "번들에 IPFS 공개 안내 문구 없음"
fi

echo
if [ "$fails" -eq 0 ]; then echo "m4-02: ALL PASS"; exit 0; fi
echo "m4-02: $fails 건 실패" >&2
exit 1
