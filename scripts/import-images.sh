#!/usr/bin/env bash
# workload 이미지를 k3d 노드 containerd 로 import 한다 (INF-07, ctr 직접 import). 노드에 이미 있으면 skip. idempotent.
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

# k3d image import 는 쓰지 않는다: Docker 29(containerd 이미지 스토어)에서 멀티아키 이미지를 save 하면
# 다른 플랫폼 blob 이 없어 노드 ctr 이 "content digest ... not found" 로 실패하는데, k3d 는 이를 로그(ERRO)만 남기고
# exit 0 으로 끝낸다 (F-M6-03 cold 실측: 6개 전부 실패 → 노드가 registry 에서 직접 pull). 그래서
# 호스트 플랫폼만 save 해서 노드 ctr 에 직접 import 하고, 끝나면 노드에 실제로 있는지 다시 확인한다.
case "$(uname -m)" in
	x86_64) PLATFORM=linux/amd64 ;;
	aarch64 | arm64) PLATFORM=linux/arm64 ;;
	*) echo "ERROR: 지원하지 않는 아키텍처 $(uname -m)" >&2; exit 1 ;;
esac

for img in ${todo[@]+"${todo[@]}"}; do
	echo "import $img ($PLATFORM) → $NODE"
	"$WITH_DOCKER" docker save --platform "$PLATFORM" "$img" |
		"$WITH_DOCKER" docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null ||
		{ echo "ERROR: import 실패 $img" >&2; exit 1; }
done

if [ "${#todo[@]}" -gt 0 ]; then
	node_images="$("$WITH_DOCKER" docker exec "$NODE" ctr -n k8s.io images ls -q)"
	for img in "${todo[@]}"; do
		printf '%s\n' "$node_images" | grep -qxF "$(normalize "$img")" ||
			{ echo "ERROR: import 후에도 노드에 없음 $img" >&2; exit 1; }
	done
fi
