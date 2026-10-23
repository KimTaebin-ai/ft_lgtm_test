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

# 소스 content hash 태그 (VM 에는 .git 이 없다. scripts/image-tag.sh). :latest 금지. 사용 시점에 계산(=)
BACKEND_IMAGE      = lgtm-backend:src-$(shell bash scripts/image-tag.sh backend)
# compiler 도 같은 backend/ 소스 hash (같은 Go 모듈이라 backend 코드가 바뀌면 두 태그가 함께 바뀐다)
COMPILER_IMAGE     = lgtm-compiler:src-$(shell bash scripts/image-tag.sh backend)
FRONTEND_IMAGE     = lgtm-frontend:src-$(shell bash scripts/image-tag.sh frontend)

export CLUSTER_NAME K3D_VERSION K3S_IMAGE KUBECTL_VERSION HELM_VERSION DOCKER_VERSION_STR

# 재로그인 없이 docker 그룹 권한으로 실행하는 래퍼 (docker/k3d 호출 시 앞에 붙인다)
WITH_DOCKER := scripts/with-docker.sh

.DEFAULT_GOAL := all
.PHONY: all install cluster images build deploy hosts status verify verify-m1 ipfs-check clean fclean re

all: install cluster build deploy hosts

install:
	@bash scripts/install.sh

# k3s / k3d helper 이미지는 cluster 생성 전에 docker host 로 재시도 pull (scripts/prefetch-images.sh, images.txt)
cluster:
	@bash scripts/prefetch-images.sh infra
	@bash scripts/cluster.sh

# 외부 이미지 전체 prefetch + workload k3d import (단독 실행용. 클러스터가 없으면 import 는 skip)
images:
	@bash scripts/prefetch-images.sh
	@bash scripts/import-images.sh

# prefetch(외부 이미지, 재시도) → backend + compiler + frontend build/import → workload import
# (frontend 는 Dockerfile build 단계에서 lint + test + build)
build:
	@bash scripts/prefetch-images.sh
	@BACKEND_IMAGE=$(BACKEND_IMAGE) COMPILER_IMAGE=$(COMPILER_IMAGE) bash scripts/build.sh
	@FRONTEND_IMAGE=$(FRONTEND_IMAGE) bash scripts/build-frontend.sh
	@bash scripts/import-images.sh

# observability → ipfs → app 순서 (PRD 9.1). 대기는 readinessProbe + rollout status
# Secret grafana-admin 은 없을 때만 랜덤 생성한다 (재실행해도 불변, 값은 출력하지 않는다)
# dashboards ConfigMap 은 dashboards/*.json 에서 만든다 (0개면 빈 ConfigMap)
# dummy-grafana, dummy-lgtm, dummy-ipfs 는 apply 가 prune 하지 않으므로 명시적으로 지운다 (기존 클러스터 대응)
deploy:
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/observability/00-namespace.yaml
	@kubectl --context k3d-$(CLUSTER_NAME) -n observability get secret grafana-admin >/dev/null 2>&1 || \
		kubectl --context k3d-$(CLUSTER_NAME) -n observability create secret generic grafana-admin \
			--from-literal=admin-user=admin \
			--from-literal=admin-password="$$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
	@kubectl --context k3d-$(CLUSTER_NAME) -n observability create configmap grafana-dashboards \
		$$(for f in dashboards/*.json; do [ -e "$$f" ] && printf -- '--from-file=%s ' "$$f"; done) \
		--dry-run=client -o yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/observability/
	@for s in mimir loki tempo; do \
		kubectl --context k3d-$(CLUSTER_NAME) -n observability rollout status statefulset/$$s --timeout=300s || exit 1; \
	done
	@for d in otel-collector grafana; do \
		kubectl --context k3d-$(CLUSTER_NAME) -n observability rollout status deploy/$$d --timeout=300s || exit 1; \
	done
	@kubectl --context k3d-$(CLUSTER_NAME) -n dummy delete ingress,svc,deploy dummy-grafana dummy-lgtm dummy-ipfs --ignore-not-found
	@bash scripts/wait-ingress.sh 60 grafana.lgtm.local/api/health
	@bash scripts/wait-dashboards.sh 150
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/ipfs/00-namespace.yaml
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/ipfs/
	@kubectl --context k3d-$(CLUSTER_NAME) -n ipfs rollout status statefulset/kubo --timeout=300s
	@bash scripts/wait-ingress.sh 120 ipfs.lgtm.local/ipfs/bafkqaaa
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/app/00-namespace.yaml
	@sed 's|__COMPILER_IMAGE__|$(COMPILER_IMAGE)|' k8s/app/compiler.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/compiler --timeout=120s
	@sed 's|__BACKEND_IMAGE__|$(BACKEND_IMAGE)|' k8s/app/backend.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/backend --timeout=120s
	@bash scripts/wait-backend.sh 60
	@sed 's|__FRONTEND_IMAGE__|$(FRONTEND_IMAGE)|' k8s/app/frontend.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/frontend --timeout=120s
	@bash scripts/wait-ingress.sh 60 lgtm.local

hosts:
	@bash scripts/hosts.sh

status:
	@kubectl --context k3d-$(CLUSTER_NAME) get nodes -o wide
	@kubectl --context k3d-$(CLUSTER_NAME) get pods -A
	@kubectl --context k3d-$(CLUSTER_NAME) get ingress -A

# 전체 검증: 순차 실행, 첫 실패에서 중단. verify 스크립트는 서로를 호출하지 않는다 (port-forward 충돌 방지). VM(Linux)에서만 동작한다
VERIFY_M1 = m1-01 m1-02 m1-03 m1-04
VERIFY_ALL = $(VERIFY_M1) m2-01 m2-02 m2-03 m2-04 m3-01 m3-02 m4-01 m4-02 m6-03 m3-03 m5-01 m5-02

# $(call run_verify,<타겟 이름>,<스크립트 목록>)
define run_verify
@for s in $(2); do \
	echo "==== verify $$s ===="; \
	out=$$(mktemp); \
	if bash scripts/verify/$$s.sh >"$$out" 2>&1; then cat "$$out"; rm -f "$$out"; \
	else cat "$$out"; echo "$(1) 실패: $$s" >&2; grep '^FAIL' "$$out" >&2; rm -f "$$out"; exit 1; fi; \
done
@echo "$(1): ALL PASS"
endef

verify:
	$(call run_verify,verify,$(VERIFY_ALL))

# M1 검증: m1-01 ~ m1-04 만. 실패 시 해당 스크립트의 FAIL 줄을 다시 출력한다
verify-m1:
	$(call run_verify,verify-m1,$(VERIFY_M1))

# 네트워크 상태에 의존하므로 make all 에 넣지 않는다 (scripts/ipfs-check.sh, F-M3-03)
ipfs-check:
	@bash scripts/ipfs-check.sh

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
