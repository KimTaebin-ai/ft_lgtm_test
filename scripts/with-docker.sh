#!/usr/bin/env bash
# 재로그인 없이 docker 그룹 권한으로 명령을 실행한다 (INF-03).
# usage: with-docker.sh <cmd> [args...]
# WITH_DOCKER_FORCE_SG=1 이면 직접 실행이 가능해도 sg 경로를 강제한다.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <cmd> [args...]" >&2; exit 2; }

# POSIX single-quote: ' -> '\''  (sg -c 는 /bin/sh(dash)가 해석하므로 printf %q 금지)
sq() {
	local s=${1//\'/\'\\\'\'}
	printf "'%s'" "$s"
}

if [ "${WITH_DOCKER_FORCE_SG:-}" != "1" ]; then
	if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then
		exec "$@"
	fi
fi

cmd=""
for a in "$@"; do
	cmd+="$(sq "$a") "
done
exec sg docker -c "$cmd"
