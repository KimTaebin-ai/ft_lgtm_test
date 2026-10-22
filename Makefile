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

export CLUSTER_NAME K3D_VERSION K3S_IMAGE KUBECTL_VERSION HELM_VERSION DOCKER_VERSION_STR

# 재로그인 없이 docker 그룹 권한으로 실행하는 래퍼 (docker/k3d 호출 시 앞에 붙인다)
WITH_DOCKER := scripts/with-docker.sh

.DEFAULT_GOAL := all
.PHONY: all install cluster build deploy hosts status verify verify-m1 ipfs-check clean fclean re

all: install cluster build deploy hosts

install:
	@bash scripts/install.sh

cluster:
	@bash scripts/cluster.sh

# 현재는 backend 만. compiler / frontend 이미지는 각 피처에서 추가
build:
	@BACKEND_IMAGE=$(BACKEND_IMAGE) bash scripts/build.sh

# observability → dummy 순서. 이후 ipfs, app 이 이어진다. 대기는 readinessProbe + rollout status
# Secret grafana-admin 은 없을 때만 랜덤 생성한다 (재실행해도 불변, 값은 출력하지 않는다)
# dashboards ConfigMap 은 dashboards/*.json 에서 만든다 (0개면 빈 ConfigMap)
# dummy-grafana 는 apply 가 prune 하지 않으므로 명시적으로 지운다 (기존 클러스터 대응)
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
	@kubectl --context k3d-$(CLUSTER_NAME) -n dummy delete ingress,svc,deploy dummy-grafana --ignore-not-found
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/dummy/
	@kubectl --context k3d-$(CLUSTER_NAME) -n dummy wait --for=condition=Available deploy --all --timeout=120s
	@bash scripts/wait-ingress.sh 60 lgtm.local grafana.lgtm.local/api/health ipfs.lgtm.local
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/app/00-namespace.yaml
	@sed 's|__BACKEND_IMAGE__|$(BACKEND_IMAGE)|' k8s/app/backend.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/backend --timeout=120s
	@bash scripts/wait-backend.sh 60

hosts:
	@bash scripts/hosts.sh

status:
	@kubectl --context k3d-$(CLUSTER_NAME) get nodes -o wide
	@kubectl --context k3d-$(CLUSTER_NAME) get pods -A
	@kubectl --context k3d-$(CLUSTER_NAME) get ingress -A

verify:
	@echo "TODO F-M6-02"

# M1 검증: m1-01 ~ m1-04 순차 실행, 첫 실패에서 중단. VM(Linux)에서만 동작한다
verify-m1:
	@for s in m1-01 m1-02 m1-03 m1-04; do \
		echo "==== verify $$s ===="; \
		bash scripts/verify/$$s.sh || { echo "verify-m1 실패: $$s" >&2; exit 1; }; \
	done
	@echo "verify-m1: ALL PASS"

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

# ---- F-M4-01 frontend 전용 (병렬 작업 중 본 build/deploy 에 통합하지 않음. merge 후 통합: HANDOFF 체크리스트) ----
FRONTEND_IMAGE = lgtm-frontend:src-$(shell bash scripts/image-tag.sh frontend)
.PHONY: deploy-frontend
# 이미지 빌드/import → apply → dummy-lgtm 정리(apply 는 prune 하지 않음) → 대기. cluster 와 backend 는 이미 떠 있어야 한다
deploy-frontend:
	@FRONTEND_IMAGE=$(FRONTEND_IMAGE) bash scripts/build-frontend.sh
	@kubectl --context k3d-$(CLUSTER_NAME) apply -f k8s/app/00-namespace.yaml
	@sed 's|__FRONTEND_IMAGE__|$(FRONTEND_IMAGE)|' k8s/app/frontend.yaml | kubectl --context k3d-$(CLUSTER_NAME) apply -f -
	@kubectl --context k3d-$(CLUSTER_NAME) -n dummy delete ingress,svc,deploy dummy-lgtm --ignore-not-found
	@kubectl --context k3d-$(CLUSTER_NAME) -n lgtm rollout status deploy/frontend --timeout=120s
	@bash scripts/wait-ingress.sh 60 lgtm.local
