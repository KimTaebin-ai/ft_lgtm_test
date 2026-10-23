#!/usr/bin/env bash
# dashboards/*.json 의 모든 uid 가 Grafana 에 올라와 있고 내용(title, 패널 쿼리)이 파일과 같을 때까지 기다린다.
# ConfigMap 갱신 → kubelet 볼륨 sync → provider 30초 스캔까지 최대 2분 걸려서 deploy 직후에는 비어 있을 수 있다.
# 제한 시간 안에 확인되지 않으면 빠진 uid 를 출력하고 exit 1 (make 가 실패한다).
# Grafana 는 Ingress 로 호출한다 (anonymous Editor 로 읽기 가능). /etc/hosts 에 의존하지 않는다.
# usage: wait-dashboards.sh [timeout-sec=150] [dir=dashboards]
set -euo pipefail

timeout="${1:-150}"
dir="${2:-dashboards}"

# 파일마다 uid 와 (title, 패널 쿼리 목록)을 읽어, Grafana 에서 조회한 것과 다른 uid 를 한 줄에 하나씩 출력한다.
# 출력이 비어 있으면 모두 확인된 것이다. 내용이 다른(아직 이전 버전) uid 는 "(내용 불일치)" 를 덧붙인다.
pending() {
	python3 -I - "$dir" <<'PY'
import glob, json, sys, urllib.error, urllib.request


def sig(model):
    """title 과 패널별 (title, 쿼리 문자열) 목록. Grafana 가 저장 모델에 덧붙이는 필드는 비교하지 않는다."""
    res = []

    def walk(ps):
        for p in ps or []:
            if p.get("type") == "row":
                walk(p.get("panels"))
                continue
            for t in p.get("targets") or []:
                res.append((p.get("title"), t.get("refId"), t.get("expr") or t.get("query") or ""))

    walk(model.get("panels"))
    return model.get("title"), res


for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    want = json.load(open(f))
    uid = want["uid"]
    req = urllib.request.Request("http://127.0.0.1/api/dashboards/uid/" + uid, headers={"Host": "grafana.lgtm.local"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            got = json.loads(r.read())["dashboard"]
    except Exception:
        print(uid)
        continue
    if sig(got) != sig(want):
        print(uid + " (내용 불일치)")
PY
}

shopt -s nullglob
files=("$dir"/*.json)
if [ "${#files[@]}" -eq 0 ]; then
	echo "no dashboards in $dir"
	exit 0
fi

deadline=$((SECONDS + timeout))
while true; do
	missing="$(pending)"
	if [ -z "$missing" ]; then
		echo "dashboards ready: ${#files[@]} file(s) in $dir"
		exit 0
	fi
	if [ "$SECONDS" -ge "$deadline" ]; then
		{
			echo "ERROR: ${timeout}s 안에 Grafana 에서 확인되지 않은 dashboard uid:"
			printf '%s\n' "$missing" | sed 's/^/  /'
		} >&2
		exit 1
	fi
	sleep 3
done
