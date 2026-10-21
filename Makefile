# LGTM Makefile (PRD 9.1). 미구현 타겟은 "TODO <피처ID>" 출력 후 exit 0.

# ---- 고정 버전 (확인일 2026-10-21) ----
K3D_VERSION        := v5.9.0
# F-M0-02에서 k3d --image 로 사용. 이번 피처에서는 미사용
K3S_IMAGE          := rancher/k3s:v1.37.1-k3s1
# kubectl은 K3S_IMAGE와 같은 minor
KUBECTL_VERSION    := v1.37.1
HELM_VERSION       := v3.22.1
# apt 버전 문자열(epoch 포함). docker-ce 와 docker-ce-cli 는 같은 값으로 고정
DOCKER_VERSION_STR := 5:29.9.1-1~debian.13~trixie

export K3D_VERSION K3S_IMAGE KUBECTL_VERSION HELM_VERSION DOCKER_VERSION_STR

# 재로그인 없이 docker 그룹 권한으로 실행하는 래퍼 (docker/k3d 호출 시 앞에 붙인다)
WITH_DOCKER := scripts/with-docker.sh

.DEFAULT_GOAL := all
.PHONY: all install cluster build deploy hosts status verify ipfs-check clean fclean re

all: install cluster build deploy hosts

install:
	@bash scripts/install.sh

cluster:
	@echo "TODO F-M0-02"

build:
	@echo "TODO F-M1-03"

deploy:
	@echo "TODO F-M1-01"

hosts:
	@echo "TODO F-M0-02"

status:
	@echo "TODO F-M0-02"

verify:
	@echo "TODO F-M6-02"

ipfs-check:
	@echo "TODO F-M3-03"

clean:
	@echo "TODO F-M0-02"

fclean:
	@echo "TODO F-M6-02"

re:
	@echo "TODO F-M6-02"

# 변수 조회용 (scripts/verify 에서 사용): make -s print-K3D_VERSION
print-%:
	@echo '$($*)'
