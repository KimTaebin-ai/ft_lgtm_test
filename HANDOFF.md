# HANDOFF

피처 블록은 이 줄 아래에 최신이 위로 오도록 추가한다.

<!-- 피처 블록 템플릿
## F-Mx-xx <이름> (브랜치 feat/mx-xx-<이름>)
### 한 일
### 된 것
### 안 된 것
### 다음 단계
-->

## F-M1-01 obs-backends (브랜치 feat/m1-01-obs-backends)

### 한 일
- `k8s/observability/`: namespace + Mimir/Loki/Tempo 각각 ConfigMap + StatefulSet(1) + ClusterIP Service + PVC(local-path). Ingress 없음. 모든 컨테이너 request/limit, `readinessProbe httpGet /ready`
- 이미지(확인일 2026-10-21, amd64/arm64 모두 Docker Hub 태그 API로 확인): `grafana/mimir:3.2.2`, `grafana/tempo:3.1.0`, `grafana/loki:3.7.9`. 버전은 각 GitHub `releases/latest`로 확인
- `make deploy`: `k8s/observability/` apply → `rollout status statefulset/{mimir,loki,tempo}`(readinessProbe 기반, port-forward 안 씀) → `k8s/dummy/` apply → 기존 dummy 대기
- `scripts/verify/m1-01.sh` (실패 상태로 먼저 커밋, 구현 전 VM에서 5건 실패 확인). port-forward는 verify 안에서만 사용, trap으로 정리

### 확정 결정과 이유
- 배포: 셋 다 raw manifest. Mimir 공식 chart가 distributed 위주라 monolithic에 맞지 않고, 세 백엔드의 방식을 통일하기 위해
- Collector→Mimir: `prometheusremotewrite` (`/api/v1/push`). Collector→Loki: `otlphttp` (`/otlp`). Collector 자체는 F-M1-02. (OTLP→Mimir 경로의 exemplar 전달은 확인하지 않았고 F-M1-04에서 실측)
- Mimir classic: 3.x에서 `ingest_storage.enabled` 기본값은 false이고 켜려면 명시해야 한다(https://grafana.com/docs/mimir/v3.2.x/configure/configuration-parameters/). 문서는 ingest storage를 "preferred"라 하지만 monolithic 설명(https://grafana.com/docs/mimir/v3.2.x/references/architecture/deployment-modes/)에는 언급이 없다. 그래서 `ingest_storage.enabled: false`를 명시했고 `/config`로 반영을 확인
- `max_global_exemplars_per_user` 기본값 0(비활성, experimental)이라 100000으로 설정. `/config`에서 반영 확인
- Tempo 3.x: ingester/compactor 블록 제거, monolithic은 Kafka 불필요(https://grafana.com/docs/tempo/v3.1.x/set-up-for-tracing/setup-tempo/migrate-to-3/). metrics-generator/local_blocks는 설정하지 않음(F-M5-03에서 이 문서 기준으로 다시 확인)
- Loki: schema v13 + tsdb, `allow_structured_metadata: true`, OTLP는 `/otlp/v1/logs`. 성공 응답은 200이 아니라 **204**

### Mimir ruler/alertmanager 스토리지 문제 (기록)
- 증상: Mimir CrashLoop, `module=ruler err="unable to read dir /data/ruler: open /data/ruler: no such file or directory"`. 이전에 `activity-tracker`도 `./metrics-activity.log` permission denied로 실패 → `activity_tracker.filepath: /data/metrics-activity.log`
- 확인: `docker run --rm --entrypoint /bin/mimir grafana/mimir:3.2.2 -modules` 에서 `ruler (in: all)`, `alertmanager`는 all에 포함되지 않음. 그래서 alertmanager 설정은 넣지 않았다
- 선택: `ruler_storage.backend: filesystem`, `dir: /data/ruler`(PVC 안). 이유: backend `local`은 디렉터리가 없으면 시작이 실패하고, `filesystem`(object store 방식)은 디렉터리 없이도 시작되는 것을 VM에서 확인(수정 후 `logs | grep level=error` 0건). rule/alert 기능은 쓰지 않는다
- 대안(끄는 방법): `-target=all` 대신 모듈을 나열하면 ruler를 뺄 수 있다. `-modules` 출력 기준이며 모듈 제외 문법(`-ruler`)은 문서에서 확인하지 못했다. emptyDir를 `/data/ruler`에 마운트하는 방법도 있으나 시도하지 않았다
- ring: `/config` 확인 결과 기본값 memberlist였던 것 중 `-target=all`에서 실제로 쓰는 ruler/query_scheduler/querier ring을 포함해 distributor/ingester/store_gateway/compactor ring을 inmemory로 설정. 남은 memberlist는 `distributor.ha_tracker`(비활성), `ingester.partition_ring`(ingest storage용), alertmanager, usage_tracker, overrides_exporter로 이 구성에서 쓰이지 않는 항목

### 검증표
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| verify가 구현 전에 실패 | VM `bash scripts/verify/m1-01.sh` | 확인(VM): 5건 실패, exit 1 |
| pod 3개 Ready, 컨테이너 3개 request/limit, readinessProbe /ready, PVC 3개 Bound | verify | 확인(VM) |
| 세 백엔드 /ready 200 | verify (port-forward) | 확인(VM) |
| Tempo OTLP 1건 전송 → `/api/traces/<id>` 조회 | verify | 확인(VM) |
| Loki OTLP 로그 1건 전송 → `query_range` 조회, `\| trace_id="..."` structured metadata 필터로 조회 | verify | 확인(VM) |
| Mimir `/api/v1/push` 404 아님 | verify (빈 body로 400) | 확인(VM) |
| exemplar 설정 반영 | verify (`/config` max_global_exemplars_per_user=100000) | 확인(VM) |
| ingest storage 꺼짐, multitenancy 꺼짐 | verify (`/config`) | 확인(VM) |
| pod 3개 delete 후 재기동, /ready 200, 기존 trace/log 재조회(PVC 유지) | verify | 확인(VM) |
| Ingress 없음 | verify | 확인(VM) |
| `make clean && make` → exit 0, 재실행 exit 0, 그 뒤 verify exit 0 | VM | 확인(VM) |
| 로그 `level=error`: mimir 0, tempo 0, loki 1(`ratestore ... empty ring`, 기동 직후 1회) | VM `kubectl logs` | 확인(VM) |
| `bash -n`, shellcheck(warning 이상) | mac | 확인(mac 정적) |
| amd64 VM에서의 기동 | - | 미확인 (검증 VM은 aarch64) |
| OTLP→Mimir 경로의 exemplar 전달 | - | 미확인 (F-M1-04) |
| Tempo 3.1.0 monolithic에서 compaction 등 장기 동작 | - | 미확인 (기동 직후 `backend scheduler no jobs found` 경고/에러가 보였던 적이 있으나 최종 로그에서는 0건) |

### 실측 (VM, 기동 후 verify 직후)
`kubectl top pod -n observability`: loki-0 42Mi / mimir-0 59Mi / tempo-0 29Mi (CPU 4~6m). 부하 없는 상태의 값이다.
노드 allocatable (`kubectl describe node`): cpu 4, memory 8121856Ki (약 7.75Gi). 배포 후 Allocated: requests cpu 430m / memory 828Mi, limits cpu 2300m / memory 2314Mi (dummy와 k3s 시스템 pod 포함).
request: mimir 100m/256Mi, loki 50m/192Mi, tempo 50m/192Mi (limit: mimir 1Gi, 나머지 512Mi). 이후 compiler는 request 256Mi / limit 1Gi 예정. 이 값으로 예산 부족 여부는 판단하지 않았다.

### 안 된 것
- verify는 한 번 수정했다: Loki OTLP 성공 코드(204), 재기동 직후 첫 연결 실패에 대한 재시도, port-forward 포트 전체 대기. 검사 기준을 완화한 것이 아니라 기대값/타이밍 오류 수정이다
- 부하 상태 RAM 미측정

### 다음 단계
- F-M1-02: tracesToLogs는 customQuery로 structured metadata 필터 (`| trace_id="${__trace.traceId}" | span_id="${__span.spanId}"`). Loki에서 `| trace_id="..."` 필터가 동작함은 이번에 확인
- F-M1-02: Collector → Mimir `prometheusremotewrite` `http://mimir.observability:8080/api/v1/push`(send_exemplars/resource_to_telemetry 등은 버전 문서로 확인), Collector → Loki `otlphttp` `http://loki.observability:3100/otlp`, Collector → Tempo `otlp` `tempo.observability:4317`
- F-M1-02: Grafana datasource는 provisioning. multitenancy 꺼짐이라 X-Scope-OrgId 불필요

## F-M0-02 cluster-ingress-hosts (브랜치 feat/m0-02-cluster-ingress-hosts)

### 한 일
- `scripts/cluster.sh` (`make cluster`): `k3d cluster create lgtm --image $K3S_IMAGE --servers 1 --agents 0 -p 80:80@loadbalancer -p 443:443@loadbalancer -p 4001:4001/tcp@server:0:direct -p 4001:4001/udp@server:0:direct --wait --timeout 180s`. 이미 있으면 `[skip]`. 이후 node Ready(120s) → `deploy/traefik` 생성 polling(180s) → `rollout status deploy/traefik`(180s) → IngressClass `traefik` 확인. skip 경로에서도 동일하게 대기. 실패 시 단계 이름과 함께 exit 1
- `k8s/dummy/`: namespace `dummy`, 호스트 3개 각각 Deployment + Service + Ingress(traefik). 이미지 `hashicorp/http-echo:1.0.0`(amd64/arm64 확인), 본문 `lgtm-dummy` / `grafana-dummy` / `ipfs-dummy`, resources request/limit 지정. `make deploy`가 apply 후 Available 대기, `scripts/wait-ingress.sh`로 세 호스트가 200을 낼 때까지 대기(실제 deploy는 F-M1-01부터)
- `scripts/hosts.sh` (`make hosts`): `# BEGIN lgtm` / `# END lgtm` 블록. 재실행해도 1개, 이미 최신이면 `[skip]`
- `make status`(nodes -o wide, pods -A, ingress -A), `make clean`(클러스터 삭제, 없으면 `[skip]` exit 0, /etc/hosts 안 건드림)
- `scripts/verify/m0-02.sh` (실패 상태로 먼저 커밋, VM에서 15건 실패 확인)
- HANDOFF.md F-M0-01 중복 블록 정리 (`fix: HANDOFF duplicate block`)

### 검증표
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| verify가 구현 전에 실패 | VM `bash scripts/verify/m0-02.sh` | 확인(VM): 15건 실패, exit 1 |
| 노드 Ready, VERSION = K3S_IMAGE | verify (`kubectl get nodes`, 기대 `v1.37.1+k3s1`) | 확인(VM) |
| k3d v5.9.0이 k3s v1.37.1을 지원 | 실제 `--image`로 생성 후 위 검사 | 확인(VM). 공식 호환표는 없음 |
| 4001/tcp, 4001/udp 매핑 존재 | VM `docker port k3d-lgtm-server-0` → `4001/tcp -> 0.0.0.0:4001`, `4001/udp -> 0.0.0.0:4001` (+ `[::]`) | 확인(VM): **매핑 존재까지만**. 외부에서 실제로 닿는지는 F-M3-01 |
| 세 호스트 → 127.0.0.1 | verify (`getent hosts`) | 확인(VM) |
| 세 호스트 curl 200, 본문이 서로 다름 | verify (`curl`, `lgtm-dummy`/`grafana-dummy`/`ipfs-dummy`) | 확인(VM) |
| `make cluster` 재실행 skip, 클러스터 재생성 안 함 | verify | 확인(VM) |
| `make hosts` 재실행 후 블록 1개 | verify (BEGIN/END 각 1) | 확인(VM) |
| `dummy` namespace 컨테이너 3개 모두 request/limit | verify (jsonpath) | 확인(VM) |
| `make clean && make cluster && make deploy && make hosts` | VM 실행 | 확인(VM): exit 0 |
| `make clean && make cluster` 재생성 경로 | VM 실행 (여러 번) | 확인(VM): exit 0 |
| `make` 처음(클러스터 없음)부터 끝까지, 그리고 재실행 | VM `make` | 확인(VM): 둘 다 exit 0, 재실행 `[skip]` 6줄 |
| `make clean`이 클러스터 없을 때 통과, /etc/hosts 유지 | VM `make clean` 2회 연속 | 확인(VM): exit 0, hosts 블록 1개 유지 |
| `bash -n`, shellcheck(warning 이상), `make -n` | mac | 확인(mac 정적) |
| amd64 VM, 클러스터가 stopped 상태일 때 skip 경로 | - | 미확인 |

### 결정 / 주의
- `@server:0:direct`는 k3d 공식 문서(v5.9.0 cluster create 페이지)에 예시가 없다. 근거는 소스 `pkg/client/ports.go`(TransformPorts: `direct`는 지정한 단일 노드의 ports에 기록, 2개 이상이면 에러). 실제 동작은 위 `docker port`로 확인했다
- 4001은 생성 시점에만 매핑된다. 이미 있는 클러스터는 skip하므로 매핑을 바꾸려면 `make clean`
- 대기 방식 변경 이유: 생성 직후에는 `helm-install-traefik` job이 아직 없을 수 있어 `kubectl wait job/...`은 즉시 not found로 실패한다. 그래서 `deploy/traefik` 생성 polling → rollout status → IngressClass 순서로 했다(VM에서 helm-install-traefik이 1회 재시작했지만 통과)
- verify의 resources 검사는 `dummy` namespace로 한정. kube-system의 svclb/coredns 등 k3s가 띄우는 pod는 우리가 제어할 수 없어 검사하면 항상 실패한다 (PRD INF-08의 "모든 pod"는 우리가 만든 pod 기준으로 해석)
- 구현 중 발견: Deployment Available 직후에도 Traefik이 라우트를 반영하기 전에는 503이 나온다(첫 verify에서 lgtm/grafana 503). `make deploy`가 `scripts/wait-ingress.sh`로 200을 기다리게 해 해결. verify는 완화하지 않음

### 안 된 것
- 4001 외부 도달(NAT, 공유기 포트포워딩 포함)은 F-M3-01
- amd64 VM 미검증(검증한 VM은 arm64), stopped 클러스터 재시작 경로 없음(`make clean && make cluster`로 복구)
- 호스트 PC에서의 접속(README 옵션)은 이번 범위 밖

### 다음 단계
- F-M1-01: `make deploy`를 observability 스택 배포로 확장(더미 `grafana.lgtm.local`부터 교체)
- F-M3-01: 4001 외부 도달 검증
- README Instructions에 `sudo apt install -y make git` 사전 조건 명시 (F-M6-01)

## F-M0-01 skeleton-install (브랜치 feat/m0-01-skeleton-install)

### 한 일
- 디렉토리(backend/ frontend/ k8s/ dashboards/ scripts/verify/) + `.gitkeep`, `.gitignore`
- `Makefile`: 9.1 전 타겟. 미구현은 `TODO <피처ID>` 후 exit 0. 기본 타겟 `all = install cluster build deploy hosts`
- `scripts/install.sh`: docker(공식 apt repo, docker-buildx-plugin 포함, compose 제외), kubectl/helm/k3d. 버전은 Makefile 상단 변수. arch 자동 감지, kubectl/helm/k3d는 공식 checksum 검증, idempotent(`[skip] <tool> <ver>`)
- `scripts/with-docker.sh`: 재로그인 없이 docker 그룹 권한 사용. `sg docker -c` + POSIX single-quote quoting, `WITH_DOCKER_FORCE_SG=1`로 sg 경로 강제
- `scripts/verify/m0-01.sh` (실패하는 상태로 먼저 커밋)

### 고정 버전 (2026-10-21 web 확인)
| 도구 | 버전 | 비고 |
|---|---|---|
| k3d | v5.9.0 | 기본 k3s는 v1.35.5-k3s1(VM의 `k3d version`으로 확인). `K3S_IMAGE`로 최신 minor를 명시 고정 |
| k3s (`K3S_IMAGE`) | rancher/k3s:v1.37.1-k3s1 | F-M0-02에서 `k3d --image`로 사용. 이번 피처 미사용 |
| kubectl | v1.37.1 | k3s와 같은 minor |
| helm | v3.22.1 | Helm 3 선택 이유: Helm 4(v4.3.x)가 최신이지만 Mimir/Tempo/Loki 차트와 호환 검증이 안 돼서 3.x 최신 패치로 고정 |
| docker-ce / -cli | 5:29.9.1-1~debian.13~trixie | download.docker.com trixie pool의 amd64·arm64 양쪽에 있는 최신 |

### 된 것
- mac 정적: `bash -n`, shellcheck, `make -n` 전 타겟, TODO 타겟 exit 0, mac에서 install 거부
- VM(Debian 13 trixie, arm64, 2026-10-21): docker 미설치 상태에서 `make install` 1회차 exit 0, 같은 ssh 명령 안에서 `id -nG`에 docker 없음 / 직접 `docker info` 실패(direct=1) / 래퍼 경유 성공(wrapper=0) → INF-03 확인. 2회차 `make install`은 `[skip]` 4줄만. `scripts/verify/m0-01.sh` exit 0(PASS 40), `make` exit 0
- 개발 VM은 NOPASSWD sudo 사용 중, 클린 VM 검증(F-M6-02)은 이 설정 없이

### 안 된 것
- amd64 VM 미검증(검증한 VM은 arm64). sudo 비밀번호 경로 미검증
- 새 VM에는 `make`가 없을 수 있음(Makefile이 스스로 설치 불가): `sudo apt-get install -y make`를 먼저 해야 한다. F-M6-02/README에서 다룰 것
- checksum 불일치 경로 미테스트(정상 경로만 VM 확인)
- verify 스크립트 첫 버전은 설치 여부를 `dpkg-query -W` 성공으로 판정해 compose가 미설치인데도 실패했음 → Status 기준으로 수정(커밋됨)

### 다음 단계
- README Instructions에 `sudo apt install -y make git` 사전 조건 명시 (F-M6-01)

## VM 검증 절차
Debian 13 VM에서 그대로 복붙.

```bash
git fetch origin && git checkout feat/m0-01-skeleton-install && git pull

# 0) 새 VM이면 make 부터: sudo apt-get install -y make
# 1) 고정한 docker 버전이 실제로 설치 가능한지 재확인 (repo 추가 전이면 install 후 다시 실행)
#    install 이 repo 를 추가한다. 아래 출력에 5:29.9.1-1~debian.13~trixie 가 있어야 함
sudo apt-get update -qq; apt-cache madison docker-ce | head -5
curl -sI https://download.docker.com/linux/debian/dists/trixie/InRelease | head -1

make install
make install          # 두 번째: [skip] 4줄만, 다운로드/apt 로그 없어야 함
bash scripts/verify/m0-01.sh; echo "exit=$?"
make; echo "exit=$?"
```
참고: madison 단계는 docker repo 추가 전(첫 설치 전)에는 항목이 비어 있을 수 있다. 그 경우 `make install` 이 repo 를 추가한 뒤 위 madison 명령을 다시 실행해 값을 대조한다.
