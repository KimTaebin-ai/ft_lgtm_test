# HANDOFF

피처 블록은 이 줄 아래에 최신이 위로 오도록 추가한다.

<!-- 피처 블록 템플릿
## F-Mx-xx <이름> (브랜치 feat/mx-xx-<이름>)
### 한 일
### 된 것
### 안 된 것
### 다음 단계
-->

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
| k3d | v5.9.0 | 기본 k3s는 1.32(EOL)라 `K3S_IMAGE`로 고정해서 쓴다 |
| k3s (`K3S_IMAGE`) | rancher/k3s:v1.37.1-k3s1 | F-M0-02에서 `k3d --image`로 사용. 이번 피처 미사용 |
| kubectl | v1.37.1 | k3s와 같은 minor |
| helm | v3.22.1 | Helm 3 선택 이유: Helm 4(v4.3.x)가 최신이지만 Mimir/Tempo/Loki 차트와 호환 검증이 안 돼서 3.x 최신 패치로 고정 |
| docker-ce / -cli | 5:29.9.1-1~debian.13~trixie | download.docker.com trixie pool의 amd64·arm64 양쪽에 있는 최신 |

### 된 것 (mac 정적 확인만)
- `bash -n`, shellcheck(warning 이상 0건), `make -n` 전 타겟, TODO 타겟 exit 0, mac에서 `make install` 거부, `sq()` 인자 왕복(dash 아닌 mac `sh`)

### 안 된 것 (VM 미확인)
- 실제 설치, checksum 검증 경로, skip 경로, docker 그룹 + sg 경로(dash), `scripts/verify/m0-01.sh`, `make` 전체
- 기본 k3s 버전이 아니라 K3S_IMAGE 고정이므로 `k3d version`의 k3s는 참고 출력만

### 다음 단계
- VM 검증 결과 반영 → draft PR
- F-M0-02: `make cluster` 에서 `$(WITH_DOCKER) k3d cluster create --image $(K3S_IMAGE) ...`

## VM 검증 절차
Debian 13 VM에서 그대로 복붙.

```bash
git fetch origin && git checkout feat/m0-01-skeleton-install && git pull

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
