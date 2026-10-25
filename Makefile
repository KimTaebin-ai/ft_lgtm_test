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
.PHONY: all sudo-auth install cluster images build deploy hosts status verify verify-m1 ipfs-check clean fclean re

# 순서는 prerequisite 나열 순서에 의존한다 (-j 미지원). sudo 를 쓰는 install·hosts 를 앞에 모아
# 비밀번호는 시작 직후 한 번만 묻고, 마지막 sudo 도 sudo 타임스탬프(기본 15분) 안에 끝나게 한다.
# hosts 는 클러스터와 무관하다 (wait-ingress 는 --resolve 를 쓴다).
all: sudo-auth install hosts cluster build deploy

# root 이거나 sudo 가 비밀번호 없이 되면(NOPASSWD, 타임스탬프 유효) 아무것도 하지 않는다
sudo-auth:
	@if [ "$$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then :; \
	elif ! command -v sudo >/dev/null 2>&1; then \
		echo "ERROR: sudo 가 없습니다. README Instructions 의 sudo 준비를 보세요" >&2; exit 1; \
	else echo "sudo 비밀번호를 한 번 입력하세요 (이후 make 는 다시 묻지 않습니다)"; sudo -v; fi

# 단독 실행은 sudo-auth 를 거치지 않는다: 이미 설치된 상태(verify 의 재실행)에서는 sudo 를 부르지 않으므로
# 긴 make verify 도중 비밀번호를 묻지 않게 한다. 설치가 필요하면 install.sh 의 sudo 가 직접 묻는다.
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
VERIFY_ALL = m0-01-skeleton-install m0-02-cluster-ingress-hosts $(VERIFY_M1) m2-01-compiler-service m2-02-compiler-hardening m2-03-wasmtime-exec m2-04-limits-queue \
	m3-01-kubo-node m3-02-ipfs-upload m4-01-frontend-shell m4-02-result-display m6-03-image-prefetch \
	m3-03-external-gateway m5-01-instrumentation m5-02-dashboard-metrics m5-03-dashboard-traces \
	m6-04-stability m6-01-readme m6-05-repo-layout m6-02-fresh-vm

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

# 클러스터만 지운다. /etc/hosts 와 이미지는 건드리지 않는다
clean:
	@if $(WITH_DOCKER) k3d cluster get $(CLUSTER_NAME) >/dev/null 2>&1; then \
		$(WITH_DOCKER) k3d cluster delete $(CLUSTER_NAME); \
	else echo "[skip] cluster $(CLUSTER_NAME) 없음"; fi

# clean + 직접 빌드한 이미지(lgtm-backend/compiler/frontend) 삭제 + /etc/hosts 블록 제거.
# 클러스터를 먼저 지워야 이미지를 rmi 할 수 있다. 외부 이미지, apt 패키지, 설치한 바이너리는 남긴다.
fclean: sudo-auth clean
	@imgs="$$($(WITH_DOCKER) docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^lgtm-(backend|compiler|frontend):' || true)"; \
	if [ -n "$$imgs" ]; then $(WITH_DOCKER) docker rmi $$imgs; else echo "[skip] lgtm-* 이미지 없음"; fi
	@bash scripts/setup/hosts.sh --remove

# recipe 안에서 차례로 부르므로 -j 에서도 fclean 이 끝난 뒤 all 이 시작된다
re:
	@$(MAKE) --no-print-directory fclean
	@$(MAKE) --no-print-directory all

# 변수 조회용 (scripts/verify 에서 사용): make -s print-K3D_VERSION
print-%:
	@echo '$($*)'
