#!/usr/bin/env bash
# workload 이미지를 k3d 노드 containerd 로 import 한다 (INF-07). 노드에 이미 있으면 skip. idempotent.
# env: CLUSTER_NAME (Makefile 이 export), IMAGES_FILE(기본 images.txt). 클러스터가 없으면 skip (make images 단독 실행 대응).
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME 필요}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WITH_DOCKER=scripts/with-docker.sh
IMAGES_FILE="${IMAGES_FILE:-images.txt}"
NODE="k3d-${CLUSTER_NAME}-server-0"

if ! "$WITH_DOCKER" k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
	echo "[skip] import: cluster $CLUSTER_NAME 없음"
	exit 0
fi

# docker 짧은 이름 → containerd 정규화 이름 (docker.io/library/x, docker.io/org/x)
normalize() {
	local i="$1" first="${1%%/*}"
	case "$i" in
		*/*) case "$first" in *.* | *:* | localhost) echo "$i" ;; *) echo "docker.io/$i" ;; esac ;;
		*) echo "docker.io/library/$i" ;;
	esac
}

# 노드 containerd 이미지 이름 목록. ctr → crictl 순. 둘 다 안 되면 비워 두고 전부 import (k3d import 는 멱등)
node_images="$("$WITH_DOCKER" docker exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null ||
	"$WITH_DOCKER" docker exec "$NODE" crictl images -o json 2>/dev/null | grep -oE '"[^"]+:[^"]+"' | tr -d '"' || true)"

todo=()
while read -r r img _; do
	[ "$r" = workload ] || continue
	if printf '%s\n' "$node_images" | grep -qxF "$(normalize "$img")"; then
		echo "[skip] $img (노드에 있음)"
	else
		todo+=("$img")
	fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$IMAGES_FILE")

if [ "${#todo[@]}" -gt 0 ]; then
	echo "import ${todo[*]} → k3d-$CLUSTER_NAME"
	"$WITH_DOCKER" k3d image import "${todo[@]}" -c "$CLUSTER_NAME"
fi
