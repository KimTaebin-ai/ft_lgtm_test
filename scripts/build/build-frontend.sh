#!/usr/bin/env bash
# frontend 이미지 빌드 + k3d image import. idempotent.
# env: CLUSTER_NAME, FRONTEND_IMAGE (Makefile 이 export). 태그는 소스 hash (scripts/build/image-tag.sh).
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME 필요}" "${FRONTEND_IMAGE:?FRONTEND_IMAGE 필요}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
WITH_DOCKER=scripts/lib/with-docker.sh

if "$WITH_DOCKER" docker image inspect "$FRONTEND_IMAGE" >/dev/null 2>&1; then
	echo "[skip] 이미지 $FRONTEND_IMAGE (이미 있음)"
else
	echo "build $FRONTEND_IMAGE"
	"$WITH_DOCKER" docker build -t "$FRONTEND_IMAGE" frontend/
fi

# 이전 소스 태그는 docker host 에서 정리한다 (k3d 노드 containerd 의 이전 이미지는 남는다)
"$WITH_DOCKER" docker images --format '{{.Repository}}:{{.Tag}}' lgtm-frontend |
	grep '^lgtm-frontend:src-' | grep -vxF "$FRONTEND_IMAGE" |
	xargs -r "$WITH_DOCKER" docker rmi >/dev/null 2>&1 || true

echo "import $FRONTEND_IMAGE → k3d-$CLUSTER_NAME"
"$WITH_DOCKER" k3d image import "$FRONTEND_IMAGE" -c "$CLUSTER_NAME"
