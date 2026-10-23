#!/usr/bin/env bash
# F-M4-01 frontend-shell 검증. Debian VM(Linux)에서만 실행한다.
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
NS="lgtm"
HOST="lgtm.local"
D=scripts/lib/with-docker.sh
k() { kubectl --context "$CTX" "$@"; }
# Ingress(Traefik) 경유. /etc/hosts 없이 --resolve 사용
lurl() { curl -s --max-time 15 --resolve "$HOST:80:127.0.0.1" "$@"; }

# ---- 1. frontend pod Ready + resources limit + 고정 태그 ----
ready="$(k -n "$NS" get deploy frontend -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${ready:-0}" -ge 1 ] 2>/dev/null && pass "deploy/frontend Ready (readyReplicas=$ready)" || fail "deploy/frontend Ready 아님 (readyReplicas=${ready:-없음})"

lim="$(k -n "$NS" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}/{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
case "$lim" in
	?*/?*) pass "frontend resources.limits cpu/memory 지정 ($lim)" ;;
	*) fail "frontend resources.limits cpu/memory 없음 ($lim)" ;;
esac

img="$(k -n "$NS" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
case "$img" in
	lgtm-frontend:src-*) pass "frontend 이미지 태그 소스 hash ($img)" ;;
	*) fail "frontend 이미지 태그가 lgtm-frontend:src-<hash> 가 아님 ($img)" ;;
esac
pol="$(k -n "$NS" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null)"
[ "$pol" = "IfNotPresent" ] && pass "imagePullPolicy IfNotPresent" || fail "imagePullPolicy=$pol (IfNotPresent 아님)"

# ---- 2. lgtm.local / 이 앱 HTML ----
code="$(lurl -o /tmp/m4-01.index.$$ -w '%{http_code}' "http://$HOST/")"
body="$(cat /tmp/m4-01.index.$$ 2>/dev/null)"; rm -f /tmp/m4-01.index.$$
[ "$code" = "200" ] && pass "GET http://$HOST/ → 200" || fail "GET http://$HOST/ → $code"
case "$body" in *'id="root"'*) pass "응답 HTML 에 id=\"root\" (앱 HTML)" ;; *) fail "응답 HTML 에 id=\"root\" 없음" ;; esac
case "$body" in *lgtm-dummy*) fail "응답이 dummy 텍스트 (lgtm-dummy)" ;; *) pass "dummy 텍스트 아님" ;; esac

# ---- 3. 이미지 안의 빌드 산출물에 외부 CDN URL 없음 ----
out="$(mktemp -d)"
trap 'rm -rf "$out"; [ -n "${cid:-}" ] && "$D" docker rm -f "$cid" >/dev/null 2>&1' EXIT
cid="$("$D" docker create "$img" 2>/dev/null)"
if [ -n "$cid" ] && "$D" docker cp "$cid:/usr/share/nginx/html/." "$out/" >/dev/null 2>&1 && [ -f "$out/index.html" ]; then
	n="$(find "$out" -type f | wc -l)"
	pass "이미지에서 정적 파일 추출 ($n 개)"
	cdn='(cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com|cdn\.tailwindcss\.com|code\.jquery\.com|fonts\.googleapis\.com|fonts\.gstatic\.com|ajax\.googleapis\.com|esm\.sh|skypack\.dev|cdn\.skypack)'
	hits="$(grep -rEoh "https?:(//|\\\\/\\\\/)[^\"' )]*$cdn[^\"' )]*" "$out" | sort -u)"
	if [ -z "$hits" ]; then pass "dist 에 CDN 도메인 URL 0건"; else fail "dist 에 CDN URL 발견: $(echo "$hits" | head -5 | tr '\n' ' ')"; fi
	# 참고: 그 외 http(s) 문자열 (xmlns, 주석 등 비요청 문자열 확인용)
	info "dist 의 http(s) 호스트 목록: $(grep -rEoh 'https?://[A-Za-z0-9.-]+' "$out" | sort -u | tr '\n' ' ')"
	# index.html 이 외부 리소스를 직접 참조하지 않는지
	if grep -Eq '(src|href)="https?://' "$out/index.html"; then fail "index.html 이 외부 URL 을 src/href 로 참조"; else pass "index.html 에 외부 src/href 없음"; fi
else
	fail "이미지($img)에서 /usr/share/nginx/html 추출 실패"
fi

# ---- 4. /api Ingress 회귀 없음 (backend 응답) ----
code="$(lurl -o /dev/null -w '%{http_code}' "http://$HOST/api/execute")"
[ "$code" = "405" ] && pass "GET /api/execute → 405 (backend mux)" || fail "GET /api/execute → $code (405 기대)"
resp="$(lurl -X POST -H 'Content-Type: application/json' -d '{"language":"rust","code":"fn main(){}"}' "http://$HOST/api/execute")"
case "$resp" in *'"status"'*) pass "POST /api/execute → backend JSON (status 필드)" ;; *) fail "POST /api/execute 가 backend JSON 이 아님: ${resp:0:100}" ;; esac

# ---- 5. lint + build (Dockerfile build 단계: npm ci → npm run lint → npm run build) ----
if "$D" docker build --target build -t lgtm-frontend-verify:build frontend/ >/tmp/m4-01.build.$$ 2>&1; then
	pass "npm ci && npm run lint && npm run build 통과 (docker build --target build)"
else
	fail "frontend lint/build 실패: $(tail -5 /tmp/m4-01.build.$$ | tr '\n' ' ')"
fi
rm -f /tmp/m4-01.build.$$

echo
if [ "$fails" -eq 0 ]; then echo "m4-01: ALL PASS"; exit 0; fi
echo "m4-01: $fails 건 실패" >&2
exit 1
