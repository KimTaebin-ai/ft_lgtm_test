#!/usr/bin/env bash
# F-M5-02 dashboard-metrics 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다 (jq 없음).
# Grafana 는 Ingress(grafana.lgtm.local)로 호출하므로 port-forward 를 쓰지 않는다.
#  - 고정 uid 의 provisioned dashboard 가 있고, 모든 패널 쿼리가 /api/ds/query 로 실행되어 값이 있다
#  - 필수 3개(성공/실패/전체)는 increase(...[$__range]) 이고 성공+실패=전체, backend 를 재시작해도 값이 줄지 않는다
#  - refresh 5s, duration 패널 exemplar, UI 에서 수정/삭제할 수 없고 Grafana pod 를 지워도 파일 기준으로 복원된다
#  - scripts/wait-dashboards.sh 가 빠진 uid 를 출력하고 exit 1 로 끝난다
# 재시작한 backend/grafana 는 끝나기 전에 Ready 와 dashboard 조회를 다시 확인한다 (이어서 m1-02 가 돈다).
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
k() { kubectl --context "$CTX" "$@"; }
DASH_UID="lgtm-metrics"
DASH_FILE="dashboards/lgtm-metrics.json"
HOST="lgtm.local"
URL="http://$HOST/api/execute"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Grafana admin 비밀번호는 환경변수로만 python 에 넘긴다 (argv/프로세스 목록에 남기지 않는다)
export GF_PW="$(k -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
export GF_UID="$DASH_UID"

mkreq() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$2" >"$TMP/$1.req"; }
send() { curl -s --max-time 90 --resolve "$HOST:80:127.0.0.1" -o "$TMP/$1.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$1.req" "$URL"; }

# ---- Grafana API 도우미 (python). 모드별로 OK:/NG: 줄 또는 값을 출력한다 ----
cat >"$TMP/gpy.py" <<'PY'
import base64, json, os, re, sys, urllib.error, urllib.request

UID = os.environ["GF_UID"]
PW = os.environ.get("GF_PW", "")


def call(method, path, body=None):
    req = urllib.request.Request("http://127.0.0.1" + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Host", "grafana.lgtm.local")
    req.add_header("Authorization", "Basic " + base64.b64encode(("admin:" + PW).encode()).decode())
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, None
    except Exception:
        return 0, None


def out(ok, msg):
    print(("OK: " if ok else "NG: ") + msg)


def load():
    st, d = call("GET", "/api/dashboards/uid/" + UID)
    return d if st == 200 else None


def panels(d):
    res = []

    def walk(ps):
        for p in ps or []:
            if p.get("type") == "row":
                walk(p.get("panels"))
            else:
                res.append(p)

    walk(d["dashboard"].get("panels"))
    return res


def run(d, p, t):
    q = dict(t)
    q["datasource"] = t.get("datasource") or p.get("datasource") or {}
    q.setdefault("intervalMs", 15000)
    q.setdefault("maxDataPoints", 500)
    frm = (d["dashboard"].get("time") or {}).get("from", "now-1h")
    st, res = call("POST", "/api/ds/query", {"queries": [q], "from": frm, "to": "now"})
    frames = []
    if st == 200 and res:
        frames = ((res.get("results") or {}).get(q.get("refId", "A")) or {}).get("frames") or []
    return st, frames


def numbers(frames):
    vals = []
    for f in frames:
        fields = (f.get("schema") or {}).get("fields") or []
        cols = (f.get("data") or {}).get("values") or []
        for fld, col in zip(fields, cols):
            if fld.get("type") == "number":
                vals += [v for v in col if isinstance(v, (int, float))]
    return vals


def exemplar_ids(frames):
    ids = []
    for f in frames:
        fields = (f.get("schema") or {}).get("fields") or []
        cols = (f.get("data") or {}).get("values") or []
        for fld, col in zip(fields, cols):
            if fld.get("name") == "trace_id":
                ids += [v for v in col if isinstance(v, str)]
    return ids


def required(d):
    by = {p.get("title"): p for p in panels(d)}
    return [by.get(n) for n in ("성공 실행 수", "실패 실행 수", "전체 실행 수")]


def stat_values(d):
    vs = []
    for p in required(d):
        if not p or not p.get("targets"):
            vs.append(None)
            continue
        st, frames = run(d, p, p["targets"][0])
        n = numbers(frames)
        vs.append(n[-1] if n else None)
    return vs


mode = sys.argv[1]
if mode == "vals":
    d = load()
    print(" ".join("none" if v is None else repr(v) for v in (stat_values(d) if d else [None] * 3)))
elif mode == "title":
    d = load()
    print("" if not d else "%s|%d" % (d["dashboard"].get("title"), len(panels(d))))
elif mode == "check":
    d = load()
    out(d is not None, "GET /api/dashboards/uid/%s 가 200" % UID)
    if d is None:
        sys.exit(0)
    st, res = call("GET", "/api/search?type=dash-db&query=")
    out(st == 200 and any(x.get("uid") == UID for x in (res or [])), "/api/search 에 uid %s 존재" % UID)
    out(bool(d["meta"].get("provisioned")), "meta.provisioned=true (provisioning 파일로 올라감)")
    out(d["dashboard"].get("refresh") == "5s", "refresh=%r (기대 5s)" % d["dashboard"].get("refresh"))
    ps = panels(d)
    out(len(ps) >= 8, "패널 %d개 (필수 3 + 권장 5 이상)" % len(ps))
    for p in ps:
        for t in p.get("targets") or []:
            st, frames = run(d, p, t)
            n = numbers(frames)
            out(st == 200 and len(n) > 0, "쿼리 non-empty: [%s] %s refId=%s (HTTP %s, 값 %d개)" % (p.get("title"), (t.get("expr") or "")[:70], t.get("refId"), st, len(n)))
    rq = required(d)
    rx = re.compile(r"^sum\(increase\(lgtm_executions_total(\{[^}]*\})?\[\$__range\]\)\)$")
    for name, p in zip(("성공", "실패", "전체"), rq):
        ok = bool(p) and p.get("type") == "stat" and len(p.get("targets") or []) == 1 and bool(rx.match(p["targets"][0].get("expr", "")))
        out(ok, "필수 패널 %s: stat + sum(increase(lgtm_executions_total...[$__range])) 형태 (%s)" % (name, (p or {}).get("targets", [{}])[0].get("expr")))
    v = stat_values(d)
    if None in v:
        out(False, "필수 3개 패널 값을 읽지 못함 %s" % v)
    else:
        out(abs(v[0] + v[1] - v[2]) < 0.01, "성공(%.2f) + 실패(%.2f) = 전체(%.2f)" % (v[0], v[1], v[2]))
        out(v[0] >= 4 and v[1] >= 1, "부하 반영: 성공 %.2f >= 4, 실패 %.2f >= 1 (increase 외삽 오차 1 허용)" % (v[0], v[1]))
    ex = [p for p in ps if "exemplar" in (p.get("title") or "")]
    ok = len(ex) == 1 and any(t.get("exemplar") for t in ex[0].get("targets") or [])
    out(ok, "duration 시계열 패널 하나에 exemplar target")
    if ok:
        ids = []
        for t in ex[0]["targets"]:
            if t.get("exemplar"):
                st, frames = run(d, ex[0], t)
                ids += exemplar_ids(frames)
                if not ids:
                    sys.stderr.write("DIAG exemplar 응답 frame: %s\n" % json.dumps([[f.get("schema", {}).get("name"), [x.get("name") for x in f.get("schema", {}).get("fields", [])]] for f in frames])[:600])
        out(len(ids) > 0 and all(re.fullmatch(r"[0-9a-f]{32}", i) for i in ids), "ds/query 응답에 exemplar trace_id %d개 (32자리 hex)" % len(ids))
elif mode == "edit":
    d = load()
    m = json.loads(json.dumps(d["dashboard"]))
    m["title"] = m["title"] + " (UI 수정)"
    st, _ = call("POST", "/api/dashboards/db", {"dashboard": m, "overwrite": True, "folderUid": d["meta"].get("folderUid", "")})
    out(400 <= st < 500, "UI/API 로 provisioned dashboard 저장 시도 → HTTP %s (4xx 거부 기대)" % st)
    st, _ = call("DELETE", "/api/dashboards/uid/" + UID)
    out(400 <= st < 500, "API 로 provisioned dashboard 삭제 시도 → HTTP %s (4xx 거부 기대)" % st)
    d2 = load()
    out(bool(d2) and d2["dashboard"].get("title") == d["dashboard"].get("title"), "수정/삭제 시도 뒤에도 title 이 파일 그대로")
PY
gpy() { python3 -I "$TMP/gpy.py" "$@"; }
# gpy 모드 출력(OK:/NG:)을 pass/fail 로 바꾼다
relay() {
	local line
	while IFS= read -r line; do
		case "$line" in
		"OK: "*) pass "${line#OK: }" ;;
		"NG: "*) fail "${line#NG: }" ;;
		esac
	done
}

# ---- 0. 파일 점검 ----
python3 -I - "$DASH_FILE" <<'PY' >"$TMP/file.out" 2>&1
import json, os, sys, glob
path = sys.argv[1]
res = []
try:
    d = json.load(open(path))
except Exception as e:
    print("NG: %s 가 유효한 JSON 이 아님: %s" % (path, e)); sys.exit(0)
print("OK: %s 유효한 JSON" % path)
print(("OK" if d.get("uid") == "lgtm-metrics" else "NG") + ": 고정 uid=%r (기대 lgtm-metrics)" % d.get("uid"))
uids = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "datasource" and isinstance(v, dict):
                uids.add(v.get("uid"))
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
print(("OK" if uids == {"mimir"} else "NG") + ": datasource 참조 uid 집합=%s (기대 {'mimir'}, Tempo/Loki 패널은 F-M5-03)" % sorted(map(str, uids)))
total = sum(os.path.getsize(f) for f in glob.glob("dashboards/*.json"))
print(("OK" if total < 120 * 1024 else "NG") + ": dashboards/*.json 합계 %d바이트 (< 120KB, kubectl apply last-applied annotation 256KB 한도 보호)" % total)
PY
relay <"$TMP/file.out"
keys="$(k -n observability get configmap grafana-dashboards -o json 2>/dev/null | python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin).get("data",{}))))' 2>/dev/null)"
case " $keys " in *" $(basename "$DASH_FILE") "*) pass "ConfigMap grafana-dashboards 에 $(basename "$DASH_FILE") 포함 (keys: $keys)" ;; *) fail "ConfigMap grafana-dashboards 키에 $(basename "$DASH_FILE") 없음 (keys: '$keys')" ;; esac

# ---- 1. wait-dashboards.sh: 정상 종료, 빠진 uid 는 출력하고 exit 1 ----
bash scripts/wait-dashboards.sh 150 >"$TMP/wd.out" 2>&1 && pass "wait-dashboards.sh: dashboards/ 의 모든 uid 확인 후 exit 0" || { fail "wait-dashboards.sh 실패: $(tail -3 "$TMP/wd.out")"; }
mkdir -p "$TMP/fakedash"
printf '{"uid":"no-such-uid-m5-02","title":"x","panels":[]}\n' >"$TMP/fakedash/x.json"
bash scripts/wait-dashboards.sh 6 "$TMP/fakedash" >"$TMP/wd2.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q "no-such-uid-m5-02" "$TMP/wd2.out"; then pass "wait-dashboards.sh: 없는 uid 는 이름을 출력하고 exit 1 (rc=$rc)"; else fail "wait-dashboards.sh 없는 uid 처리 rc=$rc out=$(tail -3 "$TMP/wd2.out")"; fi

# ---- 2. 부하: success 5, compile_error 2, exit 3 1 ----
mkreq ok 'fn main() { println!("hi"); }'
mkreq ce 'fn main() { let x = undefined_ident_m502; }'
mkreq ex 'fn main() { std::process::exit(3); }'
bad=0
for i in 1 2 3 4 5; do [ "$(send ok)" = 200 ] || bad=$((bad + 1)); done
for i in 1 2; do [ "$(send ce)" = 200 ] || bad=$((bad + 1)); done
[ "$(send ex)" = 200 ] || bad=$((bad + 1))
[ "$bad" = 0 ] && pass "부하 8건 전송 (HTTP 200)" || fail "부하 요청 ${bad}건이 HTTP 200 아님"
info "export(5초) + collector batch 반영을 위해 15초 대기"
sleep 15

# ---- 3. dashboard 존재 / refresh / 모든 패널 쿼리 / 필수 3개 / exemplar ----
gpy check 2>"$TMP/check.err" | relay
[ -s "$TMP/check.err" ] && cat "$TMP/check.err" >&2

# ---- 4. backend 재시작 후에도 필수 3개 값이 줄지 않는다 ----
read -r B1 B2 B3 <<<"$(gpy vals)"
info "재시작 전 성공/실패/전체 = $B1 / $B2 / $B3"
k -n lgtm rollout restart deploy/backend >/dev/null 2>&1
k -n lgtm rollout status deploy/backend --timeout=180s >/dev/null 2>&1 && bash scripts/wait-backend.sh 60 >/dev/null 2>&1 && pass "backend 재시작 후 Ready, ingress 연결" || fail "backend 재시작 후 Ready/ingress 확인 실패"
bad=0
for i in 1 2 3; do [ "$(send ok)" = 200 ] || bad=$((bad + 1)); done
[ "$bad" = 0 ] && pass "재시작 후 요청 3건 HTTP 200" || fail "재시작 후 요청 ${bad}건 실패"
A1=none; A2=none; A3=none
for i in $(seq 1 12); do
	sleep 5
	read -r A1 A2 A3 <<<"$(gpy vals)"
	python3 -I -c 'import sys
b=float(sys.argv[1]); a=sys.argv[2]
sys.exit(0 if a!="none" and float(a) > b + 1 else 1)' "${B3:-0}" "$A3" 2>/dev/null && break
done
info "재시작 후 성공/실패/전체 = $A1 / $A2 / $A3"
python3 -I - "$B1" "$B2" "$B3" "$A1" "$A2" "$A3" <<'PY' | relay
import sys
def f(x):
    try: return float(x)
    except Exception: return None
b = [f(x) for x in sys.argv[1:4]]; a = [f(x) for x in sys.argv[4:7]]
names = ("성공", "실패", "전체")
if None in a or None in b:
    print("NG: 재시작 전후 패널 값을 읽지 못함 before=%s after=%s" % (b, a)); sys.exit(0)
for n, x, y in zip(names, b, a):
    print(("OK" if y >= 0 and y > 0 and y >= x - 0.5 else "NG") + ": 재시작 후 %s 패널 %.2f -> %.2f (음수/0/감소 아님)" % (n, x, y))
print(("OK" if a[2] > b[2] + 1 else "NG") + ": 재시작 후 새 요청이 전체에 반영 (%.2f -> %.2f)" % (b[2], a[2]))
PY

# ---- 5. UI/API 수정·삭제 거부, Grafana pod 를 지워도 파일 기준으로 복원 ----
T0="$(gpy title)"
gpy edit | relay
k -n observability delete pod -l app=grafana --wait=true >/dev/null 2>&1
k -n observability rollout status deploy/grafana --timeout=180s >/dev/null 2>&1 && bash scripts/wait-ingress.sh 60 grafana.lgtm.local/api/health >/dev/null 2>&1 && pass "Grafana pod 삭제 후 Ready, ingress 연결" || fail "Grafana pod 삭제 후 Ready/ingress 확인 실패"
T1=""
for i in $(seq 1 30); do T1="$(gpy title)"; [ -n "$T1" ] && break; sleep 5; done
[ -n "$T1" ] && [ "$T1" = "$T0" ] && pass "Grafana pod 삭제 후 dashboard 가 같은 title·패널 수로 복원 ($T1)" || fail "Grafana pod 삭제 후 dashboard 복원 불일치 (전 '$T0' / 후 '$T1')"

# ---- 6. 재시작한 구성요소 복구 확인 (이어서 m1-02 가 돈다) ----
k -n lgtm rollout status deploy/backend --timeout=120s >/dev/null 2>&1 && pass "종료 전 backend Ready" || fail "종료 전 backend Ready 아님"
bash scripts/wait-backend.sh 60 >/dev/null 2>&1 && pass "종료 전 backend ingress 연결" || fail "종료 전 backend ingress 연결 안 됨"
k -n observability rollout status deploy/grafana --timeout=120s >/dev/null 2>&1 && pass "종료 전 grafana Ready" || fail "종료 전 grafana Ready 아님"
bash scripts/wait-dashboards.sh 150 >"$TMP/wd3.out" 2>&1 && pass "종료 전 dashboard uid 다시 조회됨" || fail "종료 전 dashboard uid 조회 실패: $(tail -2 "$TMP/wd3.out")"

if [ "$fails" -eq 0 ]; then echo "ALL PASS (m5-02)"; exit 0; fi
echo "FAILED: ${fails}건 (m5-02)" >&2
exit 1
