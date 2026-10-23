# LGTM — Claude Code 규칙

기준 문서: docs/en.subject.pdf (최종) > docs/LGTM_PRD.pdf. 충돌하면 subject.
PRD와 다르게 구현해야 하면 구현하지 말고 멈춰서 "PRD 변경: A → B, 이유"로 묻는다.
PDF는 필요한 섹션만 읽는다.

## 스택

Debian 13 VM, k3d (k3s + Traefik) / backend: Go + wasmtime-go (cgo)
compiler: rustc 단일 파일 → wasm32-wasip1, 별도 pod / frontend: Vite + React + Monaco (로컬 번들)
IPFS: Kubo / OTel Collector (contrib) → Tempo, Mimir (monolithic), Loki / Grafana provisioning

## 구조

backend/ frontend/ k8s/ dashboards/ scripts/verify/ docs/ Makefile README.md HANDOFF.md

## 작업 방식

- 피처 1개 = 브랜치 feat/mX-NN-<이름> 1개 = draft PR 1개. main 직접 커밋 금지
- plan mode로 계획만 제시 → 승인 후 구현
- 실패하는 검증 (scripts/verify/<피처>.sh 또는 테스트)을 먼저 커밋 → 구현
- 완료 시 검증표 (주장 / 확인 방법 / 결과). 실제로 실행한 명령과 출력만 "확인됨"
- HANDOFF.md 맨 위에 피처 블록 추가: 한 일 / 된 것 / 안 된 것 / 다음 단계
- 커밋 후 git push는 실행. gh pr create --draft는 명령만 출력하고 멈춘다
- 개발 호스트는 macOS, 실행 대상은 Debian 13 VM (ssh lgtm-vm). VM 검증: rsync -a --delete --exclude .git ./ lgtm-vm:~/lgtm/ 후 ssh 실행. macOS 실행 결과는 검증으로 치지 않는다
- 버전·기본값·API는 WebFetch나 실제 명령 출력으로 확인한 값만 쓴다
- pod가 CrashLoop이면 먼저 logs --previous | grep level=error로 첫 에러를 찾는다. 같은 수정으로 2번 실패하면 멈추고 첫 에러 줄을 보고한다
- 원인 불명 간헐 실패는 정보 수집 1회 후 HANDOFF에 기록하고 진행. 재현 시도를 반복하지 않는다

## 금지

- 클라우드 서비스, 외부 registry push, 런타임 CDN 로드 (Monaco 포함)
- 손으로 하는 설정. Grafana datasource/dashboard는 provisioning 파일로만
- k3d image import 이미지에 :latest 태그나 imagePullPolicy Always
- resources request/limit 없는 pod
- 범위 밖 파일 수정, 범위 밖 리팩터링
- metric label에 CID, hash 같은 high-cardinality 값
- Makefile 타겟은 idempotent, 재로그인 없이 새 VM에서 동작해야 함
- 개발 호스트는 macOS, 실행 대상은 Debian 13 VM (ssh lgtm-vm). 스크립트는 bash + GNU 도구 기준
- VM 검증: rsync -a --delete --exclude .git --exclude node_modules ./ lgtm-vm:~/lgtm/ 후 ssh lgtm-vm 'cd ~/lgtm && ...'. macOS 실행 결과는 검증으로 치지 않는다
- 개발 반복 중 make clean 금지. make 또는 make build deploy로 갱신. make clean && make와 make verify 전체는 PR 직전 1회
- PR 직전 검증: make build deploy → 이 피처 verify + 영향받는 verify(이유를 검증표에). make clean && make + 전체 verify는 Makefile/k8s/images.txt 변경 시와 마일스톤 마지막 피처에서만.
- 반복 중 검증은 이번 피처의 verify 스크립트만
- 원인 불명 간헐 실패는 정보 수집 1회 후 HANDOFF에 기록하고 진행. 재현 시도를 반복하지 않는다
- VM 작업(rsync, make, verify) 전에 `ssh lgtm-vm 'mkdir ~/.lgtm-vm.lock'`으로 lock을 잡고, 실패하면 다른 세션이 사용 중이므로 멈추고 보고한다. 끝나면 `rmdir ~/.lgtm-vm.lock`
