# LGTM Makefile (PRD 9.1). 미구현 타겟은 "TODO <피처ID>" 출력 후 exit 0.

# ---- 고정 버전 (확인일 2026-10-21) ----
K3D_VERSION        := v5.9.0
# k3d cluster create --image 로 사용 (scripts/setup/cluster.sh)
K3S_IMAGE          := rancher/k3s:v1.37.1-k3s1
# kubectl은 K3S_IMAGE와 같은 minor
KUBECTL_VERSION    := v1.37.1
HELM_VERSION       := v3.22.1
# apt 버전 문자열(epoch 포함). docker-ce 와 docker-ce-cli 는 같은 값으로 고정
DOCKER_VERSION_STR := 5:29.9.1-1~debian.13~trixie

CLUSTER_NAME       := lgtm

# 소스 content hash 태그 (VM 에는 .git 이 없다. scripts/build/image-tag.sh). :latest 금지. 사용 시점에 계산(=)
BACKEND_IMAGE      = lgtm-backend:src-$(shell bash scripts/build/image-tag.sh backend)
# compiler 도 같은 backend/ 소스 hash (같은 Go 모듈이라 backend 코드가 바뀌면 두 태그가 함께 바뀐다)
COMPILER_IMAGE     = lgtm-compiler:src-$(shell bash scripts/build/image-tag.sh backend)
FRONTEND_IMAGE     = lgtm-frontend:src-$(shell bash scripts/build/image-tag.sh frontend)

export CLUSTER_NAME K3D_VERSION K3S_IMAGE KUBECTL_VERSION HELM_VERSION DOCKER_VERSION_STR

# 재로그인 없이 docker 그룹 권한으로 실행하는 래퍼 (docker/k3d 호출 시 앞에 붙인다)
WITH_DOCKER := scripts/lib/with-docker.sh

.DEFAULT_GOAL := all
.PHONY: all install cluster images build deploy hosts status verify verify-m1 ipfs-check clean fclean re

all: install cluster build deploy hosts

install:
	@bash scripts/setup/install.sh

# k3s / k3d helper 이미지는 cluster 생성 전에 docker host 로 재시도 pull (scripts/images/prefetch-images.sh, k8s/images.txt)
cluster:
	@bash scripts/images/prefetch-images.sh infra
	@bash scripts/setup/cluster.sh

# 외부 이미지 전체 prefetch + workload k3d import (단독 실행용. 클러스터가 없으면 import 는 skip)
images:
	@bash scripts/images/prefetch-images.sh
	@bash scripts/images/import-images.sh

# prefetch(외부 이미지, 재시도) → backend + compiler + frontend build/import → workload import
# (frontend 는 Dockerfile build 단계에서 lint + test + build)
build:
	@bash scripts/images/prefetch-images.sh
	@BACKEND_IMAGE=$(BACKEND_IMAGE) COMPILER_IMAGE=$(COMPILER_IMAGE) bash scripts/build/build.sh
	@FRONTEND_IMAGE=$(FRONTEND_IMAGE) bash scripts/build/build-frontend.sh
	@bash scripts/images/import-images.sh

# observability → ipfs → app 순서 (PRD 9.1). 대기는 readinessProbe + rollout status
# Secret grafana-admin 은 없을 때만 랜덤 생성한다 (재실행해도 불변, 값은 출력하지 않는다)
# dashboards ConfigMap 은 dashboards/*.json 에서 만든다 (0개면 빈 ConfigMap)
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
	@bash scripts/wait/wait-ingress.sh 60 grafana.lgtm.local/api/health
	@bash scripts/wait/wait-dashboards.sh 150
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/ipfs/00-namespace.yaml
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/ipfs/
	@kubectl --context k3d-$(CLUSTER_NAME) -n ipfs rollout status statefulset/kubo --timeout=300s
	@bash scripts/wait/wait-ingress.sh 120 ipfs.lgtm.local/ipfs/bafkqaaa
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/app/00-namespace.yaml
	@sed 's|__COMPILER_IMAGE__|$(COMPILER_IMAGE)|' k8s/app/compiler.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/compiler --timeout=120s
	@sed 's|__BACKEND_IMAGE__|$(BACKEND_IMAGE)|' k8s/app/backend.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/backend --timeout=120s
	@bash scripts/wait/wait-backend.sh 60
	@sed 's|__FRONTEND_IMAGE__|$(FRONTEND_IMAGE)|' k8s/app/frontend.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/frontend --timeout=120s
	@bash scripts/wait/wait-ingress.sh 60 lgtm.local

hosts:
	@bash scripts/setup/hosts.sh

status:
	@kubectl --context k3d-$(CLUSTER_NAME) get nodes -o wide
	@kubectl --context k3d-$(CLUSTER_NAME) get pods -A
	@kubectl --context k3d-$(CLUSTER_NAME) get ingress -A

# 전체 검증: 순차 실행, 첫 실패에서 중단. verify 스크립트는 서로를 호출하지 않는다 (port-forward 충돌 방지). VM(Linux)에서만 동작한다
VERIFY_M1 = m1-01-obs-backends m1-02-collector-grafana m1-03-backend-skeleton m1-04-metrics-exemplar
VERIFY_ALL = $(VERIFY_M1) m2-01-compiler-service m2-02-compiler-hardening m2-03-wasmtime-exec m2-04-limits-queue \
	m3-01-kubo-node m3-02-ipfs-upload m4-01-frontend-shell m4-02-result-display m6-03-image-prefetch \
	m3-03-external-gateway m5-01-instrumentation m5-02-dashboard-metrics m5-03-dashboard-traces \
	m6-04-stability m6-01-readme m6-05-repo-layout

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

# 네트워크 상태에 의존하므로 make all 에 넣지 않는다 (scripts/tools/ipfs-check.sh, F-M3-03)
ipfs-check:
	@bash scripts/tools/ipfs-check.sh

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
