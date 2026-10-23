#!/usr/bin/env bash
# F-M5-03 dashboard-traces 검증. Debian VM(Linux)에서만 실행한다.
# 전제: make cluster && make build deploy 가 끝난 상태. JSON 파싱은 python3 표준 라이브러리만 쓴다 (jq 없음).
# Grafana 는 Ingress(grafana.lgtm.local)로 호출하므로 port-forward 를 쓰지 않는다.
#  - 고정 uid 의 provisioned dashboard 가 있고, 4개 패널(Trace duration / Mean / Slowest / Longest) 쿼리가 /api/ds/query 로 non-empty
#  - Mimir 쿼리는 Dashboard 1 과 같은 [$__rate_interval] 을 쓴다
#  - Slowest 는 duration 조건 없이 limit 200, duration 내림차순 transformation (정렬은 브라우저에서 적용되므로 정의와 응답 field 를 대조)
#  - duration 시계열 패널 응답에 exemplar trace id 가 있다 (Mean 은 bucket target 이 겹쳐 그림)
#  - Longest(TraceQL metrics)는 지연이 있어 최대 120초 polling (실측 지연 약 50초, 1회)
#  - tempo.yaml 의 설명 주석은 ConfigMap data 블록 밖에 있다 (주석만 바꿔도 Tempo 가 재시작되지 않도록)
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
DASH_UID="lgtm-traces"
DASH_FILE="dashboards/lgtm-traces.json"
HOST="lgtm.local"
URL="http://$HOST/api/execute"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Grafana admin 비밀번호는 환경변수로만 python 에 넘긴다 (argv/프로세스 목록에 남기지 않는다)
export GF_PW="$(k -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
export GF_UID="$DASH_UID"

mkreq() { python3 -I -c 'import json,sys; print(json.dumps({"language":"rust","code":sys.argv[1]}))' "$2" >"$TMP/$1.req"; }
send() { curl -s --max-time 90 --resolve "$HOST:80:127.0.0.1" -o "$TMP/$1.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$1.req" "$URL"; }

# ---- Grafana API 도우미 (python). OK:/NG: 줄을 출력한다 ----
cat >"$TMP/gpy.py" <<'PY'
import base64, json, os, re, sys, time, urllib.error, urllib.request

UID = os.environ["GF_UID"]
PW = os.environ.get("GF_PW", "")
POLL_MAX = 120  # TraceQL metrics 는 trace 가 보이기까지 약 50초 걸린다 (F-M5-03 spike 실측 1회)
POLL_STEP = 3


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
    print(("OK: " if ok else "NG: ") + msg, flush=True)


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


def columns(frames):
    """frame 마다 {field 이름: 값 목록} 을 돌려준다."""
    res = []
    for f in frames:
        fields = (f.get("schema") or {}).get("fields") or []
        cols = (f.get("data") or {}).get("values") or []
        res.append({"__frame": (f.get("schema") or {}).get("name"), **{fl.get("name"): col for fl, col in zip(fields, cols)}})
    return res


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
    for c in columns(frames):
        for name in ("trace_id", "traceId"):
            ids += [v for v in c.get(name, []) if isinstance(v, str)]
    return ids


def poll(d, p, t, ok):
    """ok(frames) 가 참이 될 때까지 최대 POLL_MAX 초 3초 간격. (경과 초, st, frames) 를 돌려준다."""
    t0 = time.time()
    while True:
        st, frames = run(d, p, t)
        if st == 200 and ok(frames):
            return int(time.time() - t0), st, frames
        if time.time() - t0 >= POLL_MAX:
            return int(time.time() - t0), st, frames
        time.sleep(POLL_STEP)


def find(d, title_part):
    m = [p for p in panels(d) if title_part.lower() in (p.get("title") or "").lower()]
    return m[0] if m else None


mode = sys.argv[1]
if mode == "check":
    d = load()
    out(d is not None, "GET /api/dashboards/uid/%s 가 200" % UID)
    if d is None:
        sys.exit(0)
    st, res = call("GET", "/api/search?type=dash-db&query=")
    out(st == 200 and any(x.get("uid") == UID for x in (res or [])), "/api/search 에 uid %s 존재" % UID)
    out(bool(d["meta"].get("provisioned")), "meta.provisioned=true (provisioning 파일로 올라감)")
    out(d["dashboard"].get("refresh") == "5s", "refresh=%r (기대 5s)" % d["dashboard"].get("refresh"))

    # 1. Mimir 패널: rate 구간 통일 + non-empty + exemplar
    for key in ("Trace duration over time", "Mean duration"):
        p = find(d, key)
        out(p is not None, "패널 '%s' 존재" % key)
        if p is None:
            continue
        ts = p.get("targets") or []
        for t in ts:
            e = t.get("expr") or ""
            out("[$__rate_interval]" in e and not re.search(r"\[\d+[smh]\]", e), "[%s] rate 구간이 $__rate_interval (Dashboard 1 과 동일): %s" % (key, e[:90]))
            st, frames = run(d, p, t)
            n = numbers(frames)
            out(st == 200 and len(n) > 0, "[%s] 쿼리 non-empty refId=%s (HTTP %s, 값 %d개)" % (key, t.get("refId"), st, len(n)))
        ex = [t for t in ts if t.get("exemplar")]
        out(len(ex) >= 1, "[%s] exemplar target 존재" % key)
        ids = []
        for t in ex:
            ids += exemplar_ids(run(d, p, t)[1])
        out(len(ids) > 0 and all(re.fullmatch(r"[0-9a-f]{32}", i) for i in ids), "[%s] 응답에 exemplar trace_id %d개 (32자리 hex)" % (key, len(ids)))

    # 2. Slowest: duration 조건 없음, limit 200, duration 내림차순
    p = find(d, "Slowest executions")
    out(p is not None, "패널 'Slowest executions' 존재")
    if p is not None:
        t = (p.get("targets") or [{}])[0]
        out((t.get("query") or "").strip() == '{ name = "POST /api/execute" }', "Slowest 쿼리가 duration 조건 없는 { name = \"POST /api/execute\" } (%r)" % t.get("query"))
        out(t.get("limit") == 200, "Slowest limit=%r (기대 200)" % t.get("limit"))
        out(p.get("type") == "table", "Slowest 패널 type=%r (기대 table)" % p.get("type"))
        st, frames = run(d, p, t)
        cs = [c for c in columns(frames) if any("duration" in k.lower() for k in c if k != "__frame")]
        rows = max([len(next(v for k, v in c.items() if "duration" in k.lower())) for c in cs] or [0])
        out(st == 200 and rows >= 2, "Slowest 쿼리 non-empty (HTTP %s, duration 행 %d개)" % (st, rows))
        dur_fields = {k for c in cs for k in c if "duration" in k.lower()}
        sorts = [tr for tr in p.get("transformations") or [] if tr.get("id") == "sortBy"]
        spec = [s for tr in sorts for s in (tr.get("options") or {}).get("sort") or []]
        out(any(s.get("desc") is True and s.get("field") in dur_fields for s in spec), "Slowest sortBy transformation 이 응답의 duration field %s 를 desc 로 정렬 (정의: %s)" % (sorted(dur_fields), spec))

    # 3. Longest: TraceQL metrics, 최대 POLL_MAX 초 polling
    p = find(d, "Longest duration")
    out(p is not None, "패널 'Longest duration' 존재")
    if p is not None:
        t = (p.get("targets") or [{}])[0]
        out(re.search(r"max_over_time\(duration\)", t.get("query") or "") is not None and t.get("metricsQueryType") == "range", "Longest 쿼리가 TraceQL metrics max_over_time(duration) range (%r)" % t.get("query"))
        el, st, frames = poll(d, p, t, lambda fr: len(numbers(fr)) > 0)
        n = numbers(frames)
        out(st == 200 and len(n) > 0, "Longest 쿼리 non-empty (HTTP %s, 값 %d개, polling %d초 / 상한 %d초)" % (st, len(n), el, POLL_MAX))
        ids = exemplar_ids(frames)
        out(len(ids) > 0 and all(re.fullmatch(r"[0-9a-f]{32}", i) for i in ids), "Longest 응답에 exemplar traceId %d개" % len(ids))
        print("INFO: Longest 최댓값 %.3fs" % (max(n) if n else float("nan")), flush=True)

    # 4. 권장: 실패 trace 표
    p = find(d, "실패")
    out(p is not None, "권장 패널 '실패 trace' 존재")
    if p is not None:
        t = (p.get("targets") or [{}])[0]
        st, frames = run(d, p, t)
        rows = max([len(v) for c in columns(frames) for k, v in c.items() if k != "__frame"] or [0])
        out(st == 200 and rows > 0, "실패 trace 쿼리 non-empty (HTTP %s, 행 %d개): %s" % (st, rows, t.get("query")))
PY
gpy() { python3 -I "$TMP/gpy.py" "$@"; }
# gpy 출력(OK:/NG:/INFO:)을 pass/fail/info 로 바꾼다. fails 가 부모 shell 에 남도록 relay < <(...) 로 호출한다
relay() {
	local line
	while IFS= read -r line; do
		case "$line" in
		"OK: "*) pass "${line#OK: }" ;;
		"NG: "*) fail "${line#NG: }" ;;
		"INFO: "*) info "${line#INFO: }" ;;
		esac
	done
}

# ---- 0. 파일 점검 ----
python3 -I - "$DASH_FILE" <<'PY' >"$TMP/file.out" 2>&1
import json, os, sys, glob
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print("NG: %s 가 유효한 JSON 이 아님: %s" % (path, e)); sys.exit(0)
print("OK: %s 유효한 JSON" % path)
print(("OK" if d.get("uid") == "lgtm-traces" else "NG") + ": 고정 uid=%r (기대 lgtm-traces)" % d.get("uid"))
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
print(("OK" if uids == {"mimir", "tempo"} else "NG") + ": datasource 참조 uid 집합=%s (기대 mimir, tempo 고정)" % sorted(map(str, uids)))
total = sum(os.path.getsize(f) for f in glob.glob("dashboards/*.json"))
print(("OK" if total < 120 * 1024 else "NG") + ": dashboards/*.json 합계 %d바이트 (< 120KB, kubectl apply last-applied annotation 256KB 한도 보호)" % total)
# tempo.yaml: ConfigMap data 블록 안에는 # 주석이 없고(주석만 바꿔도 Tempo 가 재시작되지 않게), 파일 위쪽 주석은 3.x 기준이다
lines = open("k8s/observability/tempo.yaml").read().split("\n")
start = next((i for i, l in enumerate(lines) if l.strip() == "tempo.yaml: |"), None)
end = next((i for i, l in enumerate(lines) if start is not None and i > start and l.strip() == "---"), len(lines))
inner = [l for l in lines[start + 1:end] if l.lstrip().startswith("#")] if start is not None else ["(data 블록 없음)"]
print(("OK" if start is not None and not inner else "NG") + ": tempo.yaml ConfigMap data 블록 안에 # 주석 없음 %s" % inner[:2])
head = "\n".join(lines[:start if start is not None else 0])
print(("OK" if "local_blocks" in head and "F-M5-03 에서" not in head else "NG") + ": tempo.yaml 상단 주석이 3.x 기준으로 local_blocks 제거를 설명 (data 블록 밖)")
PY
relay <"$TMP/file.out"
keys="$(k -n observability get configmap grafana-dashboards -o json 2>/dev/null | python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin).get("data",{}))))' 2>/dev/null)"
case " $keys " in *" $(basename "$DASH_FILE") "*) pass "ConfigMap grafana-dashboards 에 $(basename "$DASH_FILE") 포함 (keys: $keys)" ;; *) fail "ConfigMap grafana-dashboards 키에 $(basename "$DASH_FILE") 없음 (keys: '$keys')" ;; esac

# ---- 1. wait-dashboards.sh: dashboards/ 의 모든 uid 가 올라와 있다 ----
bash scripts/wait-dashboards.sh 150 >"$TMP/wd.out" 2>&1 && pass "wait-dashboards.sh: dashboards/ 의 모든 uid 확인 후 exit 0" || fail "wait-dashboards.sh 실패: $(tail -3 "$TMP/wd.out")"

# ---- 2. 부하: success 5, compile_error 2, exit 3 1 (2회, 20초 간격 — 새 histogram series 의 rate() NaN 회피) ----
mkreq ok 'fn main() { println!("hi"); }'
mkreq ce 'fn main() { let x = undefined_ident_m503; }'
mkreq ex 'fn main() { std::process::exit(3); }'
bad=0
for round in 1 2; do
	for i in 1 2 3 4 5; do [ "$(send ok)" = 200 ] || bad=$((bad + 1)); done
	for i in 1 2; do [ "$(send ce)" = 200 ] || bad=$((bad + 1)); done
	[ "$(send ex)" = 200 ] || bad=$((bad + 1))
	[ "$round" = 1 ] && { info "rate() 가 증가분을 볼 수 있도록 20초 뒤 부하를 한 번 더 보냄"; sleep 20; }
done
[ "$bad" = 0 ] && pass "부하 16건 전송 (2회, HTTP 200)" || fail "부하 요청 ${bad}건이 HTTP 200 아님"
info "export(5초) + collector batch 반영을 위해 20초 대기"
sleep 20

# ---- 3. dashboard 존재 / 패널 쿼리 / 정렬 / exemplar / Longest polling ----
relay < <(gpy check 2>"$TMP/check.err")
[ -s "$TMP/check.err" ] && cat "$TMP/check.err" >&2

if [ "$fails" -eq 0 ]; then echo "ALL PASS (m5-03)"; exit 0; fi
echo "FAILED: ${fails}건 (m5-03)" >&2
exit 1
