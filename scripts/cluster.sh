#!/usr/bin/env bash
# k3d 클러스터 생성 + Traefik 대기 (PRD INF-02, IP-05). idempotent.
# env: CLUSTER_NAME, K3S_IMAGE (Makefile이 export). docker/k3d 호출은 with-docker.sh 경유.
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME 필요}" "${K3S_IMAGE:?K3S_IMAGE 필요}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WITH_DOCKER=scripts/with-docker.sh
CTX="k3d-${CLUSTER_NAME}"
TRAEFIK_POLL_TIMEOUT=180

die() { echo "ERROR: $*" >&2; exit 1; }
k() { kubectl --context "$CTX" "$@"; }

if "$WITH_DOCKER" k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
	echo "[skip] cluster $CLUSTER_NAME (이미 있음. 포트 매핑은 생성 시점에만 적용되므로 바꾸려면 make clean)"
else
	echo "cluster $CLUSTER_NAME 생성 ($K3S_IMAGE)"
	# 4001 은 노드 컨테이너에 직접 매핑 (server:0:direct). 80/443 은 serverlb 경유.
	"$WITH_DOCKER" k3d cluster create "$CLUSTER_NAME" \
		--image "$K3S_IMAGE" \
		--servers 1 --agents 0 \
		-p "80:80@loadbalancer" \
		-p "443:443@loadbalancer" \
		-p "4001:4001/tcp@server:0:direct" \
		-p "4001:4001/udp@server:0:direct" \
		--wait --timeout 180s \
		|| die "k3d cluster create 실패"
fi

# 클러스터 생성 직후에는 traefik Deployment 가 아직 없을 수 있다 (helm-install-traefik job 이 만든다).
echo "대기: node Ready (120s)"
k wait --for=condition=Ready node --all --timeout=120s >/dev/null \
	|| die "node 가 120s 안에 Ready 가 되지 않음"

echo "대기: deploy/traefik 생성 (최대 ${TRAEFIK_POLL_TIMEOUT}s)"
deadline=$((SECONDS + TRAEFIK_POLL_TIMEOUT))
until k -n kube-system get deploy traefik >/dev/null 2>&1; do
	[ "$SECONDS" -lt "$deadline" ] || die "deploy/traefik 이 ${TRAEFIK_POLL_TIMEOUT}s 안에 생기지 않음 (kubectl -n kube-system get pods,jobs 확인)"
	sleep 2
done

echo "대기: rollout deploy/traefik (180s)"
k -n kube-system rollout status deploy/traefik --timeout=180s \
	|| die "deploy/traefik rollout 이 180s 안에 끝나지 않음"

k get ingressclass traefik >/dev/null 2>&1 || die "IngressClass traefik 없음"
echo "cluster $CLUSTER_NAME ready (traefik ingress)"
