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
- git push, gh pr create는 명령만 보여주고 멈춘다

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
