#!/usr/bin/env bash
# backend 이미지 빌드 + k3d image import (INF-07). idempotent.
# env: CLUSTER_NAME, BACKEND_IMAGE (Makefile 이 export). 태그는 소스 hash (scripts/image-tag.sh).
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME 필요}" "${BACKEND_IMAGE:?BACKEND_IMAGE 필요}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WITH_DOCKER=scripts/with-docker.sh

if "$WITH_DOCKER" docker image inspect "$BACKEND_IMAGE" >/dev/null 2>&1; then
	echo "[skip] 이미지 $BACKEND_IMAGE (이미 있음)"
else
	echo "build $BACKEND_IMAGE"
	"$WITH_DOCKER" docker build -t "$BACKEND_IMAGE" backend/
fi

# 이전 소스 태그는 docker host 에서 정리한다 (k3d 노드 containerd 의 이전 이미지는 남는다)
"$WITH_DOCKER" docker images --format '{{.Repository}}:{{.Tag}}' lgtm-backend |
	grep '^lgtm-backend:src-' | grep -vxF "$BACKEND_IMAGE" |
	xargs -r "$WITH_DOCKER" docker rmi >/dev/null 2>&1 || true

echo "import $BACKEND_IMAGE → k3d-$CLUSTER_NAME"
"$WITH_DOCKER" k3d image import "$BACKEND_IMAGE" -c "$CLUSTER_NAME"
