#!/usr/bin/env bash
# Ingress /api 라우트가 backend 에 닿을 때까지 기다린다.
# GET /api/execute 는 backend mux 의 405 (Traefik 에 라우트가 없으면 404). 계측 대상이 아니라 trace 가 남지 않는다.
# usage: wait-backend.sh <timeout-sec>
set -euo pipefail
timeout="${1:?usage: $0 <timeout-sec>}"
deadline=$((SECONDS + timeout))
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve lgtm.local:80:127.0.0.1 http://lgtm.local/api/execute || true)" = "405" ]; do
	[ "$SECONDS" -lt "$deadline" ] || { echo "ERROR: http://lgtm.local/api/execute 가 ${timeout}s 안에 backend 에 닿지 않음" >&2; exit 1; }
	sleep 2
done
echo "ingress ready: lgtm.local/api"
