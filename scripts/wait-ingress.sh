#!/usr/bin/env bash
# Ingress 라우트가 Traefik 에 반영되어 200 을 낼 때까지 기다린다.
# Deployment Available 직후에도 Traefik 이 라우트를 아직 모르면 503 이 나온다.
# /etc/hosts 에 의존하지 않도록 --resolve 로 127.0.0.1:80 에 직접 붙는다.
# usage: wait-ingress.sh <timeout-sec> <host[/path]>...   (path 생략 시 /. Grafana 는 / 가 login redirect 일 수 있어 /api/health 를 쓴다)
set -euo pipefail

[ "$#" -ge 2 ] || { echo "usage: $0 <timeout-sec> <host>..." >&2; exit 2; }
timeout="$1"; shift

for arg in "$@"; do
	h="${arg%%/*}"; path="/"
	[ "$h" = "$arg" ] || path="/${arg#*/}"
	deadline=$((SECONDS + timeout))
	until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$h:80:127.0.0.1" "http://$h$path" || true)" = "200" ]; do
		[ "$SECONDS" -lt "$deadline" ] || { echo "ERROR: http://$h$path 가 ${timeout}s 안에 200 을 내지 않음" >&2; exit 1; }
		sleep 2
	done
	echo "ingress ready: $h"
done
