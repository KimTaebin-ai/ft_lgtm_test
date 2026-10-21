# LGTM Makefile (PRD 9.1). 미구현 타겟은 "TODO <피처ID>" 출력 후 exit 0.

# ---- 고정 버전 (확인일 2026-10-21) ----
K3D_VERSION        := v5.9.0
# k3d cluster create --image 로 사용 (scripts/cluster.sh)
K3S_IMAGE          := rancher/k3s:v1.37.1-k3s1
# kubectl은 K3S_IMAGE와 같은 minor
KUBECTL_VERSION    := v1.37.1
HELM_VERSION       := v3.22.1
# apt 버전 문자열(epoch 포함). docker-ce 와 docker-ce-cli 는 같은 값으로 고정
DOCKER_VERSION_STR := 5:29.9.1-1~debian.13~trixie

CLUSTER_NAME       := lgtm

export CLUSTER_NAME K3D_VERSION K3S_IMAGE KUBECTL_VERSION HELM_VERSION DOCKER_VERSION_STR

# 재로그인 없이 docker 그룹 권한으로 실행하는 래퍼 (docker/k3d 호출 시 앞에 붙인다)
WITH_DOCKER := scripts/with-docker.sh

.DEFAULT_GOAL := all
.PHONY: all install cluster build deploy hosts status verify ipfs-check clean fclean re

all: install cluster build deploy hosts

install:
	@bash scripts/install.sh

cluster:
	@bash scripts/cluster.sh

build:
	@echo "TODO F-M1-03"

# 더미 페이지만 적용한다. 실제 deploy(observability → ipfs → app)는 F-M1-01부터
deploy:
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/dummy/
	@kubectl --context k3d-$(CLUSTER_NAME) -n dummy wait --for=condition=Available deploy --all --timeout=120s
	@bash scripts/wait-ingress.sh 60 lgtm.local grafana.lgtm.local ipfs.lgtm.local

hosts:
	@bash scripts/hosts.sh

status:
	@kubectl --context k3d-$(CLUSTER_NAME) get nodes -o wide
	@kubectl --context k3d-$(CLUSTER_NAME) get pods -A
	@kubectl --context k3d-$(CLUSTER_NAME) get ingress -A

verify:
	@echo "TODO F-M6-02"

ipfs-check:
	@echo "TODO F-M3-03"

# /etc/hosts 는 건드리지 않는다 (fclean은 F-M6-02)
clean:
	@if $(WITH_DOCKER) k3d cluster get $(CLUSTER_NAME) >/dev/null 2>&1; then \
		$(WITH_DOCKER) k3d cluster delete $(CLUSTER_NAME); \
	else echo "[skip] cluster $(CLUSTER_NAME) 없음"; fi

fclean:
	@echo "TODO F-M6-02"

re:
	@echo "TODO F-M6-02"

# 변수 조회용 (scripts/verify 에서 사용): make -s print-K3D_VERSION
print-%:
	@echo '$($*)'
