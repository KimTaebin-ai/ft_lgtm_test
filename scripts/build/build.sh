#!/usr/bin/env bash
# backend / compiler 이미지 빌드 + k3d image import. idempotent.
# env: CLUSTER_NAME, BACKEND_IMAGE, COMPILER_IMAGE (Makefile 이 export). 태그는 소스 hash (scripts/build/image-tag.sh).
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME 필요}" "${BACKEND_IMAGE:?BACKEND_IMAGE 필요}" "${COMPILER_IMAGE:?COMPILER_IMAGE 필요}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
WITH_DOCKER=scripts/lib/with-docker.sh

# build_image <이미지(repo:tag)> <Dockerfile>  (컨텍스트는 항상 backend/)
build_image() {
	local image="$1" dockerfile="$2" repo="${1%%:*}"
	if "$WITH_DOCKER" docker image inspect "$image" >/dev/null 2>&1; then
		echo "[skip] 이미지 $image (이미 있음)"
	else
		echo "build $image"
		"$WITH_DOCKER" docker build -f "backend/$dockerfile" -t "$image" backend/
	fi

	# 이전 소스 태그는 docker host 에서 정리한다 (k3d 노드 containerd 의 이전 이미지는 남는다)
	"$WITH_DOCKER" docker images --format '{{.Repository}}:{{.Tag}}' "$repo" |
		grep "^$repo:src-" | grep -vxF "$image" |
		xargs -r "$WITH_DOCKER" docker rmi >/dev/null 2>&1 || true

	echo "import $image → k3d-$CLUSTER_NAME"
	"$WITH_DOCKER" k3d image import "$image" -c "$CLUSTER_NAME"
}

build_image "$BACKEND_IMAGE" Dockerfile
build_image "$COMPILER_IMAGE" Dockerfile.compiler
