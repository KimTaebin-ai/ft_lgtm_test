#!/usr/bin/env bash
# k8s/images.txt 의 외부 이미지를 docker host 로 재시도하며 pull 한다. idempotent.
# usage: prefetch-images.sh [role...]   (role = workload|build|infra, 기본 전체)
# env:   IMAGES_FILE(기본 k8s/images.txt), PREFETCH_RETRIES(5), PREFETCH_BACKOFF(첫 대기 초, 5; 매번 2배),
#        PREFETCH_TIMEOUT(시도당 초, 300), PREFETCH_DOCKER(docker 명령, 기본 scripts/lib/with-docker.sh docker),
#        PREFETCH_SLEEP(대기 명령, 기본 sleep. 테스트에서 true)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
IMAGES_FILE="${IMAGES_FILE:-k8s/images.txt}"
RETRIES="${PREFETCH_RETRIES:-5}"
BACKOFF="${PREFETCH_BACKOFF:-5}"
TIMEOUT="${PREFETCH_TIMEOUT:-300}"
SLEEP="${PREFETCH_SLEEP:-sleep}"
read -r -a DOCKER <<<"${PREFETCH_DOCKER:-scripts/lib/with-docker.sh docker}"

roles=("$@")
[ "${#roles[@]}" -gt 0 ] || roles=(workload build infra)
[ -f "$IMAGES_FILE" ] || { echo "ERROR: $IMAGES_FILE 없음" >&2; exit 1; }

# pull_with_retry <image> : 성공 0, RETRIES 회 모두 실패 1
pull_with_retry() {
	local img="$1" i wait="$BACKOFF" t=()
	command -v timeout >/dev/null 2>&1 && t=(timeout "$TIMEOUT")
	for ((i = 1; i <= RETRIES; i++)); do
		if ${t[@]+"${t[@]}"} "${DOCKER[@]}" pull "$img"; then return 0; fi
		if [ "$i" -lt "$RETRIES" ]; then
			echo "[retry $i/$RETRIES] pull 실패: $img (${wait}s 후 재시도)" >&2
			"$SLEEP" "$wait"
			wait=$((wait * 2))
		fi
	done
	return 1
}

for role in "${roles[@]}"; do
	while read -r r img _; do
		[ "$r" = "$role" ] || continue
		if "${DOCKER[@]}" image inspect "$img" >/dev/null 2>&1; then
			echo "[skip] $img (docker host 에 있음)"
			continue
		fi
		echo "pull [$role] $img"
		pull_with_retry "$img" || { echo "ERROR: pull 실패 $img ($RETRIES 회 시도, role=$role)" >&2; exit 1; }
	done < <(grep -vE '^[[:space:]]*(#|$)' "$IMAGES_FILE")
done
echo "prefetch 완료 (${roles[*]})"
