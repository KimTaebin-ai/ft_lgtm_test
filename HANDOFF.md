# HANDOFF

피처 블록은 이 줄 아래에 최신이 위로 오도록 추가한다.

<!-- 피처 블록 템플릿
## F-Mx-xx <이름> (브랜치 feat/mx-xx-<이름>)
### 한 일
### 된 것
### 안 된 것
### 다음 단계
-->

## F-M3-01 kubo-node (브랜치 feat/m3-01-kubo-node)

### 한 일
- `k8s/ipfs/kubo.yaml`: `ipfs/kubo:v0.43.1`(GitHub releases latest 2026-09-15, Docker Hub amd64/arm64 확인), StatefulSet 1 + PVC 5Gi, Service `kubo-api`(5001) / `kubo-gateway`(8080) 분리, Ingress `ipfs.lgtm.local` → gateway 8080 만, hostPort 4001 tcp/udp, NetworkPolicy `kubo-ingress`(5001 ← ns lgtm + app=backend 만, 8080·4001 은 전체)
- 설정은 ConfigMap `kubo-init` 의 `/container-init.d/001-lgtm-config.sh` 가 매 기동 적용 (수동 설정 없음): path gateway(`UseSubdomains=false`), `Gateway.NoFetch=true`, `Swarm.ConnMgr` basic 20/60/20s, `Swarm.ResourceMgr.MaxMemory=512MiB`·`MaxFileDescriptors=4096`, `Datastore.StorageMax=4GB`, `AutoTLS.Enabled=false`. 유지: DHT, bootstrap, AutoConf, relay client, UPnP. env `IPFS_TELEMETRY=off`, `DO_NOT_TRACK=1`, `GOMEMLIMIT=800MiB`
- securityContext: runAsNonRoot(uid 1000), allowPrivilegeEscalation false, drop ALL, seccomp RuntimeDefault, automountServiceAccountToken false, enableServiceLinks false. **readOnlyRootFilesystem=true 로 동작** (쓰기 경로는 `/data/ipfs` PVC 와 `/tmp` emptyDir 뿐. VM 에서 기동·add·재시작 정상, 루트 쓰기 실패 확인)
- resources: request 100m/256Mi, limit 1 CPU/1Gi
- `k8s/dummy/ipfs.yaml` 삭제, Makefile deploy 에서 `dummy-ipfs` 를 `delete --ignore-not-found`, 순서 observability → ipfs → app. dummy namespace 는 비어 있는 채로 남음. `wait-ingress` 의 ipfs 기대값은 `ipfs.lgtm.local/ipfs/bafkqaaa`(빈 identity CID)가 200
- `scripts/verify/m3-01.sh`(먼저 실패 상태로 커밋 123faa5), `make verify` 순서에 m3-01 추가 (m2-02 뒤)

### 된 것 (검증표, 모두 VM `lgtm-vm`, 로그 `~/lgtm-logs/m3-01-*.log`)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0 | `m3-01-final.log` | **첫 실행 exit 2 (실패)**: observability 단계에서 `grafana/mimir:3.2.2` pull 이 `registry-1.docker.io` timeout (DeadlineExceeded), tempo rollout 300s 초과. kubo 단계 도달 전. 같은 체인의 바로 다음 `make` 는 exit 0 |
| 재실행 `make` exit 0 | 같은 로그 `MAKE2_EXIT=0`, 추가로 한 번 더 `m3-01-make3.log` `MAKE3_EXIT=0` | 확인(VM) |
| 이전 실행(kubo 단계 포함 `make clean && make` + 재실행, `m3-01-make.log`) | startupProbe 405 로 두 번 다 실패 → 수정 후 | 아래 "실패 이력" |
| `make verify` 전체 exit 0 (m1-01~m4-02, m3-01 포함) | `m3-01-final.log` `VERIFY_EXIT=0` | 확인(VM) |
| `m3-01.sh` ALL PASS: pod Ready/limit/PVC Bound/securityContext/uid 1000/telemetry off, 설정 키, ipfs add → gateway 200(301 아님)+내용 일치, 디렉토리 목록, `/api/v0/id` 404(POST·GET), Ingress 에 5001 없음, 없는 CID → 404 (0s), swarm peers 20, listen tcp/4001·quic-v1, hostPort, 호스트 4001 tcp/udp listen, 호스트 127.0.0.1:4001 에서 multistream 응답, pod 삭제 후 같은 CID·pin 유지 | `make verify` 안 m3-01 | 확인(VM) |
| NetworkPolicy 강제: 다른 ns pod → 5001 실패, lgtm/app=backend 라벨 pod → 5001 성공, 다른 ns → gateway 8080 성공, 정책 삭제 시 같은 pod 연결 **성공**(대조군), 복구 후 다시 실패 | m3-01.sh 7번 | 확인(VM) |
| Kubo 메모리 실측 | `kubectl top pod -n ipfs` | 53Mi / 50m (최종 `make` 후 idle), 90Mi / 133m (add·pin·peers 20 직후 측정). limit 1Gi, 재시작 0. 계획 예상 150~350MB 보다 낮음 |
| `ipfs.io` 등 외부 gateway 에서 CID 도달 | — | **미확인** (F-M3-03) |
| NAT 너머 4001 도달 (UTM/공유기 포워딩) | — | **미확인** (F-M3-03). 확인한 것은 VM 호스트 127.0.0.1:4001 까지 |

### 실패 이력 / 열린 문제
- 1차(`m3-01-make.log`): kubo startupProbe `httpGet /api/v0/version` 이 405 (Kubo `/api/v0/*` 는 POST 전용). 데몬은 `Daemon is ready` 였지만 probe 실패로 재시작 반복 → `tcpSocket: api` 로 수정 (커밋 fix: kubo startupProbe). 주의: StatefulSet 은 Ready 아닌 pod 를 롤링 업데이트하지 않아서 `kubectl delete pod kubo-0` 이 필요했다
- 2차: m3-01.sh 가 `lgtm-probe` ns 를 m2-02 와 공유 → m2-02 cleanup(`--wait=false`)이 아직 terminating 이라 probe pod 생성 실패. 그 상태에서 "차단" 검사가 pod 없음 때문에 **거짓 PASS** 가 됐다. 전용 ns `ipfs-probe` + 삭제 대기 + exec 가능 단언 추가. k3s 노드 컨테이너에 `nc` 없음 → 호스트에서 multistream 헤더 송수신으로 변경
- 최종 체인 첫 `make` 실패(위 표)는 Docker Hub pull timeout 으로 이번 변경과 무관해 보이나, 같은 VM 네트워크 문제가 새 VM 첫 `make` 에서 재발하면 감점 위험. 이미지 pull 재시도/사전 pull 은 이번 범위 밖이라 손대지 않음
- `scripts/verify/m0-02.sh` 는 dummy ns 에 파드 3개 이상을 기대한다 (`make verify` 에 없는 스크립트). 이번에 수정하지 않았고 현재 통과하지 않을 것으로 예상 (실행해 보지 않음)
- 로그에 `failed to sufficiently increase receive buffer size` (quic-go UDP 버퍼, 208KiB). 기능에는 영향 없었으나 QUIC 처리량은 줄 수 있음. `net.core.rmem_max` 는 VM 호스트 설정이라 건드리지 않음
- PRD 변경 없음

### 다음 단계
- F-M3-02 ipfs-upload: backend 가 `kubo-api.ipfs.svc.cluster.local:5001` 로 업로드 (NetworkPolicy 는 이미 lgtm/app=backend 허용). backend egress 정책이 생기면 5001 허용 필요. `ipfs.cid` attribute, 10s timeout

## F-M2-02 compiler-hardening (브랜치 feat/m2-02-compiler-hardening)

### 한 일
- `backend/internal/compile/denylist.go`: rustc 실행 전 소스 deny-list. raw 소스 + 주석 제거 뷰(중첩 `/* */` 인식, 문자열·raw string·char 안의 `//`는 주석 아님) 두 뷰를 모두 검사. 위반 시 422, 첫 줄 `error: LGTM 소스 정책 위반 [규칙ID] N행: 설명` (소스 줄 내용은 응답에 넣지 않음) → backend `firstErrorLine`이 그대로 `compile_error` message로 사용 (backend 수정 없음)
- 규칙: `deny-include-macro`(include_str/include_bytes/option_env 이름 단독, `include!`, 인자 위치 `include`), `deny-env-macro`(`env!`, 인자 위치 `env`), `deny-rename`(`include|env` 뒤 `as`), `deny-mod-file`(`mod 이름;`), `deny-path-attr`(`#[..path..]`, `cfg_attr(.. path =`), `deny-incbin`(`.incbin`)
- 인자 위치 규칙은 `use` 문을 지운 텍스트에서 찾는다 (`use std::{env, fs};` 오탐 방지). 재명명(`as`)은 원문 전체에서 잡는다
- `runner.go`: rustc 환경변수 `rustcEnv()`로 분리, PATH/RUSTUP_HOME/CARGO_HOME/HOME/TMPDIR 5개만 (상속 없음). 단위 테스트로 키 집합과 비밀값 미포함 확인
- `k8s/app/compiler.yaml`: `readOnlyRootFilesystem: true`, `enableServiceLinks: false`, NetworkPolicy `compiler-ingress`(app=backend → 8080), `compiler-egress`(kube-dns 53 UDP/TCP, observability/otel-collector 4317). `/tmp` emptyDir은 추가하지 않음 (VM 기동 결과로 확정, 아래)
- `scripts/verify/m2-02.sh` (먼저 실패 상태로 커밋 e34bf0c)

### 확정 결정 (PRD 변경)
- **PRD 변경: 7.3 수용 기준 (b) = 격리 + 소스 deny-list. deny-list에 PRD에 없던 `include!` 추가.** 이유: 결과가 IPFS에 영구 공개되므로 소스 단계 차단을 추가. `include!`는 파일을 Rust 소스로 끼워 넣어 rustc 에러 메시지에 파일 내용이 찍히는 경로
- 사용자 추가 지시로 `[(,\[{]\s*(?:\w+::)*(?:r#)?env\s*[),\]}]`(인자 위치 env)와 `deny-incbin` 포함

### rustc 실측 (Mac rustc, `rustc -` 로 stdin 컴파일. VM 검증 아님, 규칙 설계 근거)
- 동작함(= 우회 실재): `r#include_str!`, `std::r#env!`, `use std::env as e; e!(..)`, `use std::include_str as x; x!(..)`, `include_str /* /* */ */ !(..)`(중첩 주석), `m!(include_str)`/`m!(env)`/`m!(r#env)`(`$n:ident` 매개변수), `#[cfg_attr(all(), path = "..")] mod x;`
- 동작 안 함: `$p:path` 로 `$p!(..)` ("macro expansion ignores `!`")

### 한계 (의도된 오탐 / 미탐 가능성)
- 정규식 기반이라 **문자열·주석 안의 패턴도 차단**: `println!("include_str!")`, `// env!("X")`
- 인자 위치 규칙 때문에 **`f(env)`, `g(a, include)` 처럼 변수 이름이 env/include인 함수 인자 전달도 차단** (use 문 안은 제외). 테스트 `TestCheckSourceKnownFalsePositives`가 이 동작을 고정
- `#[..path..]`는 속성 안 어디든 `path` 단어면 차단 (`#[doc = "path"]` 오탐)
- 주석 제거 뷰는 완전한 lexer가 아님. 그래서 raw 뷰와 함께 검사한다. 정적 패턴은 완전하지 않으며 **최종 방어는 격리 계층**(read-only rootfs, 환경변수 명시 목록, SA 토큰 없음, NetworkPolicy)

### verify 구조 정리 (F-M4-02 후속 요청)
- verify 스크립트는 다른 verify 스크립트를 호출하지 않는다: m1-03의 m1-01/02 호출, m2-01의 `make verify-m1` 호출 제거, m2-02는 처음부터 호출하지 않음
- Makefile: `make verify` = m1-01 → m1-02 → m1-03 → m1-04 → m2-01 → m2-02 → m4-01 → m4-02 순차, 첫 실패에서 중단하고 FAIL 줄 출력. `make verify-m1`은 m1만. 둘 다 `run_verify` 매크로 공유
- `scripts/verify/lib-pf.sh`(공용 `pf_forward`/`pf_stop`): kubectl이 실제로 로컬 포트를 열었는지(`Forwarding from 127.0.0.1:PORT`)와 **포트마다 HTTP 응답(코드 != 000)** 을 확인한 뒤 반환. kubectl이 죽으면 출력을 stderr로 남긴다. 스크립트별 로컬 포트 대역을 분리(기존 값 + 1000×스크립트 번호)
- **관찰된 사실**: 정리 전 구조로 처음 `make verify`를 돌렸을 때 m1-01 재기동 단계에서 `address already in use`(19080/14100/14200)로 실패했고, 그 포트를 `kubectl port-forward` 프로세스 3개가 점유 중이었다(스크립트 종료 후에도 생존). 원인은 `k()` 함수를 `&`로 띄우면 `$!`가 subshell PID라 `kill`이 kubectl에 닿지 않는 것. kubectl을 직접 띄우고 `pkill -P`로 자식도 정리하도록 고친 뒤 재현되지 않음. **m2-01 안 verify-m1의 m1-02 code=000 두 번 실패가 이 원인인지는 이번에 재현·증명하지 않았다** (중첩 호출 제거 + 포트 대역 분리 + HTTP 확인으로 구조적으로 막았을 뿐)

### 된 것 / 안 된 것 (검증표, 모두 VM `lgtm-vm`, 로그 `~/lgtm-logs/m2-02-*.log`)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0 | nohup, `m2-02-make1.log` `MAKE_EXIT=0` | 확인(VM) |
| 재실행 `make` exit 0 | `m2-02-make2.log` | 확인(VM), `MAKE_EXIT=0` |
| 공격 12종(include_str!/공백/core::/r#/include!/env!/`m!(env)`/`#[path]` mod/cfg_attr mod/`use as`+`x!`/중첩 주석 gap/incbin) → `compile_error` + `LGTM 소스 정책 위반 [규칙]`, 응답에 `root:x:0:0` 없음 | `m2-02.sh` 1번 | 확인(VM) |
| 정상 예제(struct/trait/iterator/`std::env::args`/인라인 mod/`path` 변수) → success | `m2-02.sh` 2번 | 확인(VM) |
| 격리 계층 단독: (KUBERNETES_* 제외) 다른 Service 주소·비밀값 환경변수 없음, `/var/run/secrets/kubernetes.io` 없음, 루트 FS 쓰기 실패(`/work`는 성공), 1.1.1.1:80 / backend Service / API 서버 연결 실패, otel-collector:4317 연결 성공 | `m2-02.sh` 3번 | 확인(VM) |
| **k3s가 NetworkPolicy를 강제**: 다른 namespace pod → compiler:80 실패, 정책 2개 임시 삭제 시 같은 pod 연결 **성공**(대조군), 복구 후 다시 실패, backend → compiler `/api/execute` success | `m2-02.sh` 4번 | 확인(VM) |
| `readOnlyRootFilesystem=true / enableServiceLinks=false / automountServiceAccountToken=false`, 이 상태에서 compile 응답 `\0asm`, `/tmp` emptyDir 없이 동작 | `m2-02.sh` 5번 | 확인(VM). `/tmp` 추가 불필요 |
| deny-list·rustcEnv 단위 테스트 | VM golang 컨테이너 `go test ./cmd/compiler/... ./internal/...` (`m2-02.sh` 6번) | 확인(VM) |
| `make verify`(8개 순차) exit 0 | `m2-02-verify3.log`, `m2-02-verify4.log` (연속 2회) | 확인(VM). 아래 실패 이력 참고 |

### 안 된 것 / 열린 문제 / 실패 이력
- `make verify` 실패 이력: (1) 1번째: m1-01 포트 점유(위 원인, 수정함). (2) 2번째: m2-02 환경변수 검사가 `KUBERNETES_PORT_443_TCP=tcp://10.43.0.1:443`에 걸림 → 아래 항목. 수정 후 3회, 4회 연속 통과
- **`enableServiceLinks: false`로도 `KUBERNETES_*` 8개(SERVICE_HOST/PORT/PORT_443_TCP* 등)는 K8s가 항상 주입한다** (VM `env` 실측: 그 외 Service 변수는 없음). 그래서 m2-02 검사를 "KUBERNETES_* 제외 다른 Service 주소·비밀값 없음"으로 바꾸고, API 서버(`KUBERNETES_SERVICE_HOST:443`) 연결 실패를 별도로 확인(실측: Connection refused). rustc 프로세스 환경에는 이 변수들이 없다 (`rustcEnv` 5개 키 단위 테스트). 지시한 기준 "환경변수 목록에 다른 Service 주소 없음"을 K8s 동작에 맞게 좁힌 것이므로 이의가 있으면 알려 달라
- 15초 timeout은 VM에서 재현하지 않았고 단위 테스트 유지 (선택 항목, 시도하지 않음)

### 다음 단계
- F-M2-03 wasmtime-exec

## F-M4-02 result-display (브랜치 feat/m4-02-result-display)

### 한 일
- `frontend/src/api.ts`: `execute()` 가 throw 대신 `ExecuteOutcome` 반환 (`ok` / `too_large`(413) / `busy`(429) / `http_error`(그 외 비정상, 400 포함) / `bad_body`(비JSON·비객체·status 없음) / `network`)
- `frontend/src/ResultView.tsx`(신규): success(stdout/stderr 구분, `Output truncated (10kB)` 배지) / compile_error(rustc 메시지 `<pre>`) / runtime_error / timeout(`Time limit exceeded (5s)`) / memory_limit(`Memory limit exceeded (10MB)`) / internal_error(`서버 내부 오류, 잠시 후 다시 시도` + message) / 알 수 없는 status 는 원문. `timings_ms` 표시. 출력은 JSX 텍스트 노드만 (`dangerouslySetInnerHTML` 없음)
- IPFS 링크 2개(`http://ipfs.lgtm.local/ipfs/<cid>`, `https://ipfs.io/ipfs/<cid>`, 새 탭, `noopener noreferrer`): cid 를 `^[A-Za-z0-9]{10,100}$` 로 검증한 뒤 직접 조립. 응답의 `ipfs_url` 은 href 에 쓰지 않고 null/빈 값(=생성 실패) 판정에만 사용. null → `공유 링크 생성 실패(IPFS timeout)`, cid 검증 실패 → 링크 없이 안내
- trace_id 표시 + 복사 버튼. `http://lgtm.local` 은 보안 컨텍스트가 아니라 `navigator.clipboard` 가 없으므로 fallback(텍스트 자동 선택 + `선택됨 — Ctrl+C로 복사`)이 정상 경로다. clipboard 거부 시에도 같은 fallback. Grafana 링크는 만들지 않음 (저장소에 Tempo datasource uid/Explore URL 형식 근거 없음)
- `App.tsx`: Run 옆 안내 `실행한 코드와 결과는 IPFS에 영구 공개됩니다`
- 테스트: vitest 5.0.5 + jsdom + @testing-library (`ResultView.test.tsx`, `api.test.ts`, `App.test.tsx`, 39건). 실패 상태로 먼저 커밋(`cdf40ab`) 후 구현
- `frontend/Dockerfile` build 단계: `npm run lint && npm test && npm run build` (이미지 빌드가 테스트 통과를 포함)
- make 통합: `build` 에 `build-frontend.sh`, `deploy` 에 frontend.yaml apply + rollout + `wait-ingress lgtm.local`. `deploy-frontend` 타겟과 `k8s/dummy/lgtm.yaml` 제거. `dummy-lgtm` 은 `delete --ignore-not-found` 로 정리 유지
- `scripts/verify/m4-02.sh` 신규 (frontend pod/restart, dummy-lgtm 없음, `/` 앱 HTML, `/api` 회귀, 번들 CDN 0건, src 에 dangerouslySetInnerHTML 없음, 번들에 공개 안내 문구)
- verify 수정(범위 확장, 필요해서 함): `m1-03.sh` 8번(`/`·`/healthz` 가 dummy 텍스트가 아니라 frontend HTML 인지), `m1-03.sh` 9번(하위 스크립트 FAIL 줄 노출), `m1-02.sh`, `m2-01.sh`, Makefile `verify-m1` (아래)

### PRD 변경 (확정)
- **FE-07**: `ipfs.lgtm.local` 링크 + `https://ipfs.io/ipfs/<cid>` 두 개. 이유: subject "share with the world"
- **status `internal_error` 추가** (F-M2-01 확정 사항, 화면 처리 추가). 플랫폼 장애
- FE-08 문구: PRD "실행한 코드는 IPFS에 영구 공개됩니다" → "실행한 코드와 결과는 IPFS에 영구 공개됩니다" (사용자 지시)

### m1-02 간헐 실패 대응 (사용자 지시로 이번에 처리)
- `m1-02.sh`: Collector 로그 error 검사를 스크립트 시작 시각 이후(`kubectl logs --since-time`)로 한정, 기동 오류는 `restartCount==0` 으로 확인. `Exporting failed` 제외 예외 제거
- `make verify-m1`: 실패 시 해당 스크립트의 `FAIL` 줄을 그대로 다시 출력. `m2-01.sh` 의 verify-m1 실패 메시지와 `m1-03.sh` 9번도 `tail -5` 대신 FAIL 줄을 담음
- 이 변경으로 첫 FAIL 줄이 처음 보이게 됨 (아래 "안 된 것")

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| vitest 39건 통과, `npm run lint`, `npm run build` | Mac `frontend/` 에서 실행 | 확인(mac) |
| 테스트가 구현 전에 실패 | 구현 전 `npx vitest run` (3 파일 실패, 11건 실패 출력 확인) 후 `cdf40ab` 커밋 | 확인(mac) |
| `make clean && make` exit 0, 재실행 `make` exit 0 (frontend 이미지 빌드 + Dockerfile 안 `npm test` 포함) | VM, 로그 `~/lgtm-logs/m4-02-full-run.log` (`MAKE1_OK`/`MAKE2_OK`) | 확인(VM). 커밋 62598cf 기준 |
| `m4-01.sh` ALL PASS (이미지 `docker build --target build` = lint+test+build 포함) | 위 체인 | 확인(VM) |
| `m4-02.sh` ALL PASS (frontend pod Ready/restart 0, dummy-lgtm 없음, `/` 앱 HTML, `/api` 회귀, 번들 CDN 0건, src 에 dangerouslySetInnerHTML 없음, 공개 안내 문구 번들 포함) | 위 체인 | 확인(VM). 새로 만든 클러스터 기준 |
| `m1-03.sh` + `m2-01.sh` 통과 (m1-03 8번 수정 후, verify-m1 포함) | VM, `m4-02-run2.log` `CHAIN2_OK` | 확인(VM). **커밋 2c1bc12 기준, m1-02 변경(62598cf) 이전 스크립트** |
| 새 `m1-02.sh` + `make verify-m1` 단독 실행 통과 (Collector restartCount 0, since-time error 0건, `Exporting failed` 예외 없이) | VM 단독 `make verify-m1` → `verify-m1: ALL PASS` | 확인(VM). 1회 |
| 브라우저에서 Run → 결과 화면 | 미실시 | **미확인** (수동 체크리스트) |
| 413 화면 | api/ResultView mock 테스트만 | **backend 에 413 이 아직 없음** (F-M2-04). 실서버 미확인 |
| S3 (runtime error / 제한 초과) 화면 | mock 테스트만 | **F-M2-03 전이라 실서버 미확인** |
| 기존 클러스터에서 `dummy-lgtm` 이 `delete --ignore-not-found` 로 정리됨 | — | **미확인** (VM 을 `make clean` 으로 새로 올렸기 때문에 이 경로를 타지 않음) |

### 안 된 것 / 열린 문제
- **m2-01 안에서 호출되는 `make verify-m1` 의 m1-02 간헐 실패 (미해결, 원인 미확인)**. 새 m1-02 스크립트로 전체 체인(`m4-02-full-run.log`)을 돌렸을 때 `m2-01.sh` 9번이 실패했고 체인이 거기서 멈춤(최종 `make verify-m1` 단계는 실행되지 않음). 첫 FAIL 줄: `FAIL: Collector /v1/traces code=000` (이어서 `/v1/logs`, `/v1/metrics` 도 000, 그 뒤 Tempo 404 / Loki·Mimir 0건은 그 결과). 같은 m1-02 에서 앞 단계(restartCount 0, error 로그 0건, Grafana, datasource 3개)는 통과 → 6번 OTLP `port-forward` 호출만 연결 실패. 이번에 추가한 로그 검사 변경과는 무관한 지점
  - 이력: 전체 체인 첫 실행에서도 m2-01 의 verify-m1 이 m1-02 에서 실패(당시 FAIL 줄이 안 남아 같은 실패인지는 **확인 못 함**). 이후 m2-01 단독 재실행에서는 m1-03 8번(dummy 가정, 수정함)이 원인이었고, 수정 후 m1-03+m2-01 은 통과, `make verify-m1` 단독도 통과. 즉 m1-02 실패는 `m2-01.sh` 안에서 호출될 때만 2회 관측
  - 추정(증명 안 됨): `pf_start` 는 로컬 포트가 열렸는지만 보고(kubectl 이 listen 하면 통과) upstream 연결을 확인하지 않는다. m2-01 의 선행 단계(compiler 중단·복구, 동시 3건, 도커 go test) 직후라 Collector 쪽 연결이 아직 안정되기 전일 수 있다. 다음 실패 때는 `pf_start` 의 kubectl 출력(현재 `/dev/null`)을 먼저 본다
  - 같은 실패 2번이라 이 브랜치에서는 더 고치지 않고 멈춤
- `m4-02.sh` 에는 413 검사가 없다 (backend 413 미구현)
- Grafana 링크 미구현 (위 사유)
- 번들 크기는 F-M4-01 과 동일하게 2.9MB 대(monaco). 범위 밖
- `npm audit`: F-M4-01 에 적은 monaco-editor/dompurify low 외에 vitest/jsdom 추가분은 확인하지 않음

### 수동 확인 체크리스트 (VM Firefox, `http://lgtm.local`)
- [ ] **S1 정상 실행**: 예제 그대로 Run → status 정상 표시, stdout, `compile/execute/ipfs_upload` timings, IPFS 링크 2개(`ipfs.lgtm.local`, `ipfs.io`)가 새 탭으로 열림(ipfs.io 는 오프라인이면 열리지 않아도 href 가 `https://ipfs.io/ipfs/<cid>` 인지만 확인), Run 근처 공개 안내, trace_id 복사 버튼 → "선택됨 — Ctrl+C로 복사" 와 텍스트 선택
- [ ] **S2 문법 오류**: `let x = ;` 로 Run → compile_error, rustc 메시지가 monospace 로 그대로 표시, IPFS 링크 2개
- [ ] S3 (runtime error / 제한 초과)는 **F-M2-03 전이라 mock 테스트로만 확인**됐다. F-M2-03 에서 실제 화면 확인 필요
- [ ] 네트워크 탭의 요청 도메인이 `lgtm.local` 하나인지 (ipfs 링크 클릭 제외)

### 다음 단계
1. m2-01 안 verify-m1 의 m1-02 간헐 실패 원인 확인 (`pf_start` upstream 확인 / kubectl 출력 보존). 위 추정은 증명 전
2. F-M2-03 (execute) 이후 S3 화면을 실서버로 확인
3. F-M2-04 의 413 이 들어오면 `m4-02.sh` 에 413 검사 추가

## F-M2-01 compiler-service (브랜치 feat/m2-01-compiler-service)

### 한 일
- `backend/cmd/compiler` + `internal/compile`: `POST /compile`(text/plain) → rustc → 200 wasm / 422 rustc stderr / 504 timeout / 500 내부. `GET /healthz`
- rustc: `rustc --edition 2021 --target wasm32-wasip1 -C opt-level=1 --crate-type bin --crate-name main -o out.wasm main.rs` (cwd = 요청별 임시 디렉토리, 상대 경로라 에러 메시지에 `req-XXXX` 경로가 새지 않음)
- 요청별 `os.MkdirTemp("/work")` + `defer RemoveAll`(성공/실패/timeout/취소 공통). 시작 시 `/work` 잔여물 청소
- timeout 15초(semaphore 획득 이후부터), `Setpgid` + `Cancel`에서 `kill(-pgid, SIGKILL)` + `WaitDelay 2s`. semaphore 2: 초과 요청은 거부하지 않고 대기 (429는 F-M2-04)
- tracing: `otelhttp` server span 이름 `rustc`(service.name=lgtm-compiler, `telemetry.Setup(ctx, serviceName)`로 파라미터화). 로그는 backend와 같은 slog fan-out
- backend: compile 단계를 compiler HTTP 호출로 교체. execute / ipfs.upload는 stub 유지
- 이미지 `backend/Dockerfile.compiler`(golang:1.27.3-trixie 빌드 → `rust:1.99.1-slim-trixie` + `rustup target add wasm32-wasip1`, uid 65532). 태그 `lgtm-compiler:src-<backend/ 해시>`. `scripts/build.sh`는 두 이미지 루프, Makefile `build`/`deploy`에 compiler 추가
- `k8s/app/compiler.yaml`: Deployment 1 / ClusterIP Service `compiler:80` / Ingress 없음 / emptyDir `/work` / request 250m·256Mi, limit 2·2Gi. backend에 `COMPILER_URL` env

### 확정 결정과 이유 (PRD 변경 포함)
- **PRD 변경 1 (SEC-10)**: "compile memory 1GB pod limit" → "compiler pod limit 2Gi(동시 2개 합계), request 256Mi". 이유: SEC-07 동시 2와 10장 1GB×2 계산에 맞춤
- **PRD 변경 2 (6.2 status)**: `internal_error` 추가. 이유: 플랫폼 장애와 사용자 코드 오류를 metric(`lgtm_executions_total{status}`)과 trace에서 구분. 분류: rustc 422 / compile timeout 504 → `compile_error`, compiler 연결 실패 / 그 외 5xx·4xx / wasm 8MiB 초과 → `internal_error`(HTTP 200, 스키마 동일, message에 요약, stderr 비움, root span ERROR)
- **traceparent는 `otelhttp.NewTransport`를 쓰지 않고 직접 주입**: transport가 HTTP client span을 하나 더 만들어 rustc의 parent가 compile이 아니게 된다 (PRD 8.3 트리 compile → rustc). compile span ctx에서 `otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))`, 일반 `http.Client{Timeout: 20s}`. 단위 테스트(`TestTraceparentParentIsCompileSpan`)가 traceparent의 parent == compile span id, backend span 4개(추가 client span 없음)를 확인
- edition 2021: 널리 쓰이는 예제 코드와 호환. 2024는 `gen` 예약어·unsafe extern 등 변경 위험
- Rust 이미지: `rust:1.99.1-slim-trixie`. 근거 URL: https://static.rust-lang.org/dist/channel-rust-stable.toml (stable 1.99.1, wasm32-wasip1 rust-std 존재), https://hub.docker.com/v2/repositories/library/rust/tags?name=slim-trixie (태그 존재)
- backend compile timeout 20초 = compiler 15초 + 5초 여유. wasm 응답 상한 8MiB: 이후 Wasmtime 적재·IPFS 업로드와 backend 메모리 limit(128Mi) 보호. 실측 hello world는 약 2.1MB(opt-level=1, 디버그 정보 포함)
- 트리거: `__slow__`는 유지(compile 실제 시간을 뺀 나머지를 execute/ipfs stub에 나눠 전체 2~3초). `__fail_compile__` 분기는 제거(실제 rustc 에러로 대체)

### m1 verify / load.sh 수정 (최소)
- `scripts/load.sh`, `m1-03.sh`: `__fail_compile__` 코드를 주석만 있던 것에서 `let x = ;` 문법 오류 + 마커로 변경 (이제 실제 rustc가 실패해야 compile_error)
- `m1-03.sh`: 정상 trace span 4 → 5개(rustc 추가), 자식 span 목록에 `rustc` 포함, `rustc`는 parent가 compile이므로 "parent = root" 검사에서 제외, 실패 trace 3 → 4개
- backend compile span에 `compile started/finished` 로그를 복구(m1-03 Loki 검사가 compile span_id 로그를 요구)

### 이미지 크기 (VM `docker image ls`)
- lgtm-compiler:src-72063c37732d **1.32GB**, lgtm-backend 177MB

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 `make` exit 0 | VM, 로그 `MAKE1_OK`/`MAKE2_OK` | 확인(VM). 커밋 5ab6b79+19a25a5 기준 |
| compiler pod Ready, limit 2/2Gi, request 256Mi, 태그 고정, Ingress 없음 | `m2-01.sh` 1번 | 확인(VM) |
| POST /compile 200 + `\0asm`(2174529 bytes), 문법 오류 422 + rustc 메시지, 요청 후 `/work` 비어 있음 | `m2-01.sh` 2~4번 | 확인(VM) |
| /api/execute success, Tempo service 2개, rustc parent == compile span id | `m2-01.sh` 5번 | 확인(VM) |
| /api/execute 문법 오류 → compile_error + rustc stderr | `m2-01.sh` 6번 | 확인(VM) |
| compiler 다운 → HTTP 200 internal_error, message 있음, root span ERROR | `m2-01.sh` 6b | 확인(VM) |
| compile 시간 (예제 `println!`, pod 재시작 직후 첫 요청 = cold / 그 다음 = warm): cold **0.53s** → **1.21s**(두 번 실행), warm **0.06s** | `m2-01.sh` 2번 INFO | 확인(VM). cold는 실행마다 편차가 있음 |
| 15s timeout·프로세스 그룹 kill·임시 디렉토리 삭제·semaphore(peak 2, 대기)·backend handler(internal_error 3종 포함) | `go test ./cmd/compiler/... ./internal/...` (golang 컨테이너). **timeout은 VM에서 15초를 직접 재현하지 않고 단위 테스트(느린 명령 + 자식 프로세스 주입, timeout 단축)로 대체** | 확인(VM) |
| 동시 3건 compile 전부 200 (1.76s/1.54s/1.54s), compiler 로그 started 3건, 동시 실행 peak 2 (2+1 직렬화) | `m2-01.sh` 7번 | 확인(VM) |
| `make verify-m1` 통과 (m1-03 수정·compile span 로그 복구 반영) | `m2-01.sh` 9번 | 확인(VM) |
| `bash scripts/verify/m2-01.sh` exit 0 (`ALL PASS (m2-01)`, `make verify-m1` 포함) | VM, 로그 `~/lgtm-logs/m2-01-run3.log` | 확인(VM). 3번째 실행에서 통과 (아래 이력) |

### 안 된 것 / 열린 문제
- **`m2-01.sh` 실패 이력**: 1번째 실행은 `wait`(인자 없음)가 백그라운드 port-forward를 기다려 멈춤 → 대상 PID만 기다리도록 수정. 2번째는 6b 복구 직후 동시 3건 HTTP 000, 3번째 실행은 첫 compile HTTP 000 (두 번째 발생). 이 둘의 원인으로 "svc/ port-forward가 시작 시점 pod 하나에 고정되어 Terminating 중인 옛 pod 또는 새 pod 준비 전에 붙음"을 가정하고 verify를 고침: 새 pod 하나만 Ready로 남을 때까지 대기 → `pod/<이름>`으로 port-forward → 첫 요청 `curl --retry 10 --retry-connrefused`. 고친 뒤 3번째 실행에서 통과. **원인을 pod/endpoint 상태로 직접 증명한 것은 아니다** (수정 후 재현되지 않음). 재발하면 verify의 실패 시 디버그 출력(`get pods -o wide`, pf 로그)을 먼저 본다
- 서비스(backend → compiler)는 ClusterIP DNS로 호출하며 verify 6~7번에서 통과했다. 위 HTTP 000은 verify 쪽 port-forward 문제로 판단하나, 첫 실패 때 backend → compiler 20초 timeout이 한 번 같이 있었다 (같은 시점, 원인 미확인)
- 15초 timeout은 VM에서 직접 재현하지 않고 단위 테스트로 대체 (위 표)
- 413/429, deny-list, 하드닝은 범위 밖 (F-M2-02, F-M2-04)
- compiler 이미지 1.32GB (slim rust + wasm32-wasip1 target). 크기 최적화는 하지 않음

### 다음 단계
1. F-M2-02 compiler-hardening (securityContext, `env -i`, NetworkPolicy, read-only rootfs, 7.3 deny-list)
2. F-M4-01 merge 체크리스트(아래 블록)의 build/deploy 통합은 이 브랜치가 main에 merge된 뒤 진행 (이 브랜치는 이미 origin/main 위로 rebase됨, Makefile 충돌 없음)

## F-M4-01 frontend-shell (브랜치 feat/m4-01-frontend-shell)

### 한 일
- `frontend/`: Vite 8.3.5 + React 19.3.1 + TypeScript 5.9.3(7.x 금지, typescript-eslint 8.72.0 peer `<6.1.0`) + monaco-editor 0.57.0. 전부 정확 버전 고정 + lockfile, Node 22 (`.nvmrc` 22.23.2, 빌드 이미지 `node:22.23.4-alpine`)
- Monaco 로컬 번들: `@monaco-editor/react` 미사용 (loader 에 jsdelivr URL 이 남음). `monaco-editor` 를 직접 쓰는 `src/Editor.tsx`. import 는 package `exports` 의 `./*` → `esm/vs/*.js` 매핑을 따름: `monaco-editor/editor/editor.api`, `monaco-editor/languages/definitions/rust/register`(0.57 에서 `basic-languages` 경로는 사라짐), worker `monaco-editor/editor/editor.worker?worker` (Rust 는 editor.worker 하나만 필요)
- 예제(struct/trait/iterator), Run 버튼(실행 중 disabled + spinner), 결과는 status + stdout 원문만
- dev: `vite.config.ts` 의 `/api` proxy → `LGTM_VM_URL`(기본 `http://192.168.64.8`), Host 헤더 `lgtm.local`
- 이미지: multi-stage, build 단계에서 `npm run lint && npm run build`, `nginxinc/nginx-unprivileged:1.31.7-alpine`(uid 101, 8080). 태그 `lgtm-frontend:src-<hash>` (`scripts/image-tag.sh frontend` 재사용)
- `k8s/app/frontend.yaml`(Deployment/Service/Ingress `lgtm.local /`), `scripts/build-frontend.sh`, Makefile 맨 아래 `deploy-frontend`(dummy-lgtm 은 `delete --ignore-not-found` 로 정리), `scripts/verify/m4-01.sh`
- `k8s/dummy/lgtm.yaml`, backend/, k8s/observability/, 기존 Makefile 타겟은 수정하지 않음

### emptyDir 목록 (확정: `/tmp` 하나)
- `docker run --read-only` 로 실제 기동: `--read-only` 만 주면 `mkdir() "/tmp/proxy_temp" failed (30: Read-only file system)` 로 종료. `/tmp` 만 쓰기 가능하게 하면 기동·200 응답. `/tmp` 에 생긴 것: nginx.pid, client_temp, proxy_temp, fastcgi_temp, uwsgi_temp, scgi_temp. `/var/cache/nginx` 쓰기 불필요(touch 시도는 read-only 실패, 기동엔 영향 없음)
- 이 확인은 **Mac Docker**(non-root 101, cap-drop ALL) 기준이다. k8s(VM) 기동은 아래 "안 된 것"
- `10-listen-on-ipv6-by-default.sh: can not modify default.conf` 는 정보성 로그(우리 conf 는 이미 `listen 8080`)

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `npm run lint`(eslint + tsc), `npm run build` 통과 | Mac `frontend/` 에서 실행 | 확인(mac) |
| dist 에 CDN 도메인(jsdelivr/unpkg/cdnjs/googleapis/gstatic) 0건. http(s) 호스트는 w3.org, github.com, react.dev, code.visualstudio.com, microsoft.com (주석·xmlns 문자열) | `grep -rEoh 'https?://...' dist` | 확인(mac) |
| 이미지 빌드(lint+build 포함) 성공, `--read-only --tmpfs /tmp --user 101 --cap-drop ALL` 에서 `/` 200, `id="root"` 포함, `/deep/link` SPA fallback 200 | Mac Docker 로컬 실행 | 확인(mac). VM 아님 |
| frontend pod Ready(1/1, restart 0), limit 100m/64Mi, 태그 `lgtm-frontend:src-81848450da36`, IfNotPresent | `make deploy-frontend` 후 `m4-01.sh` | 확인(VM) |
| `lgtm.local /` 200 + `id="root"`, dummy 텍스트 아님 | `m4-01.sh` | 확인(VM) |
| 이미지 안 정적 파일(6개)에 CDN 도메인 0건, index.html 외부 src/href 없음 | `m4-01.sh` | 확인(VM) |
| `/api/execute` GET 405, POST backend JSON (Ingress 회귀 없음) | `m4-01.sh` | 확인(VM) |
| `docker build --target build` (npm ci + lint + build) | `m4-01.sh` | 확인(VM) |
| `bash scripts/verify/m4-01.sh` exit 0 (ALL PASS) | VM 실행 | 확인(VM) |
| k8s 에서 readOnlyRootFilesystem + emptyDir(/tmp) 기동, nginx 로그에 emerg/error 없음 (ipv6 정보성 한 줄만) | VM `kubectl logs` | 확인(VM) |
| Mac `npm run dev`(포트 5199) 의 `/api/execute` POST → VM backend stub 응답(`stub output`) 프록시 | curl localhost:5199 | 확인(mac). 브라우저에서 Run 클릭은 미실시 |

### 안 된 것
- `m4-01.sh` 를 구현 전에 커밋했으나 당시 VM 이 꺼져 있어 "VM 에서 실패" 는 확인하지 못했다 (이후 구현 + 배포 뒤 통과만 확인)
- 브라우저(VM Firefox)에서 Run → 결과 표시와 네트워크 탭 외부 요청 0개는 **미확인** (아래 수동 절차)
- `npm audit`: monaco-editor 0.57.0 → dompurify(≤3.4.15) low 2건 (IN_PLACE 사용 경로, 우리 코드는 해당 API 미사용). 0.56.0 으로 내리면 해소된다고 나오지만 breaking 이라 그대로 둠
- 번들 index js 2.9MB (monaco 전체 editor.api). 코드 분할은 범위 밖

### 수동 확인 절차 (VM Firefox)
1. `rsync -a --delete --exclude .git --exclude node_modules --exclude dist ./ lgtm-vm:~/lgtm-fe/` 후 `ssh lgtm-vm 'cd ~/lgtm-fe && make deploy-frontend && bash scripts/verify/m4-01.sh'`
2. Firefox `http://lgtm.local` → 개발자 도구 네트워크 탭을 연 채 새로고침 → Run → status/stdout 표시
3. 네트워크 탭의 모든 요청 도메인이 `lgtm.local` 하나인지 확인 (외부 도메인 0개)

### merge 체크리스트
1. F-M2-01 merge 후 main 을 rebase 하고 Makefile 충돌을 해결한다 (이 브랜치는 Makefile 맨 아래에만 추가)
2. 본 `build` / `deploy` 타겟에 frontend 를 통합한다 (build 에 `build-frontend.sh`, deploy 에 frontend.yaml apply + `rollout status`, `k8s/dummy/lgtm.yaml` 제거와 dummy-lgtm delete 줄 정리, 그 뒤 `deploy-frontend` 는 제거하거나 별칭으로)
3. merge 후 `make clean && make` 로 새로 올려 `lgtm.local /` 가 frontend 인지 확인 (`curl -s lgtm.local | grep 'id="root"'`, `m4-01.sh`)

### 다음 단계
F-M4-02 result-display (FE-05~FE-10: 상태별 에러, IPFS 링크, 공개 안내, trace_id, 413/429)

## F-M1-04 metrics-exemplar (브랜치 feat/m1-04-metrics-exemplar)

### 한 일
- `telemetry.Setup`: `otlpmetricgrpc`(v1.47.0) + `PeriodicReader(WithInterval(5s))` → Collector. 같은 resource(`service.name=lgtm-backend`). Shutdown 순서 metric → log → trace
- `telemetry/metrics.go`: instrument 3개. bucket `0.05 … 20` 공통 (`DurationBuckets`)
- `execute/handler.go`: stage duration은 `step()`에서 stage span ctx로 `span.End()` 전에 기록, execution counter/duration은 응답 쓰기 직전 root span이 살아 있는 `r.Context()`로 기록 (otelhttp가 ServeHTTP 반환 뒤 End). duration 값은 ServeHTTP 진입 시각부터의 시간이라 root span 시작과 ms 미만 차이가 있음. 400 invalid_request는 metric 미기록
- `scripts/load.sh`: 단발 모드(`-n`, `--ok/--slow/--fail`)와 지속 모드(`-d <초> [--interval <초>]`, 정상 70/slow 15/fail 15 가중 랜덤). stdout `<kind> <status> <trace_id>`, stderr 요약. M5 dashboard 개발·디펜스 시연용. verify는 단발 모드만 사용
- `make verify-m1`: m1-01 → m1-04 순차, 첫 실패에서 중단
- `scripts/verify/m1-04.sh` (실패 상태로 먼저 커밋: VM에서 15건 실패 확인)

### 확정 결정과 이유
- **OTel 이름에 접미사를 쓰지 않는다**: `lgtm_executions`(→ `_total`), `lgtm_execution_duration` / `lgtm_stage_duration`(unit `s` → `_seconds`). 실측 Mimir 이름이 PRD와 정확히 일치함
- exemplar: otel-go sdk/metric v1.47.0은 **기본 활성**, 기본 filter `TraceBasedFilter` (`config.go newConfig`). `OTEL_GO_X_EXEMPLAR` 불필요. 바꾸려면 `WithExemplarFilter` 또는 `OTEL_METRICS_EXEMPLAR_FILTER`
- Collector `prometheus_remote_write`는 exemplar 설정 키 없이 전송함 (`pkg/translator/prometheusremotewrite/helper.go` `getPromExemplars`, v0.163.0). **collector.yaml 변경 없음**, Mimir `max_global_exemplars_per_user`는 F-M1-01에서 이미 설정
- Mimir exemplar label 키 실측: `trace_id`, `span_id` → Grafana `exemplarTraceIdDestinations.name: trace_id` 그대로 일치
- 근거 URL: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.163.0/pkg/translator/prometheusremotewrite/helper.go , https://github.com/open-telemetry/opentelemetry-specification/blob/v1.40.0/specification/compatibility/prometheus_and_openmetrics.md , https://github.com/open-telemetry/opentelemetry-specification/blob/d4b241f451674e8f611bb589477680341006ad2b/specification/configuration/sdk-environment-variables.md#exemplar

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 exit 0 | VM 실행 (`make1=0 make2=0`) | 확인(VM) |
| `make verify-m1` exit 0 (m1-01~m1-04 전부 ALL PASS) | VM 실행. m1-02 수정(아래) 후 재실행한 결과 | 확인(VM) |
| Mimir 저장 이름이 PRD와 정확히 일치: `lgtm_executions_total`, `lgtm_execution_duration_seconds_{bucket,sum,count}`, `lgtm_stage_duration_seconds_{bucket,sum,count}` | `m1-04.sh` (label/__name__/values 출력) | 확인(VM) |
| `status="success"` > 0, `status="compile_error"` > 0 | `m1-04.sh` | 확인(VM) |
| 두 histogram의 `le` 집합 == PRD bucket + `+Inf` | `m1-04.sh` | 확인(VM) |
| label 세트: executions/duration `language,status`, stage `stage`; cid/hash/sha 류 없음 | `m1-04.sh` | 확인(VM) |
| `query_exemplars`가 `trace_id`(+`span_id`) 라벨 반환, load.sh 응답 trace_id와 일치, Tempo 조회됨 | `m1-04.sh` | 확인(VM) |
| Grafana `exemplarTraceIdDestinations.name: trace_id` == 실측 키 | `m1-04.sh` (grafana.yaml 파싱 vs 실측) | 확인(VM). 설정 존재·일치만, UI 동작은 미확인 |
| load.sh 지속 모드 (`-d 6 --interval 1`) 가 요청을 계속 보내고 종료 0 | VM 실행 (total=4, errors=0) | 확인(VM). 짧은 구간만 |
| 계측 이름/unit/bucket/label/exemplar trace_id(root·stage ctx), 400은 미기록 | `go test` (ManualReader) | 확인(mac 정적). VM에서 go test는 실행 안 함 |
| Grafana Explore에서 exemplar 점 클릭 → Tempo → Related logs | — | **미확인** (위 수동 절차) |
| amd64, Mimir/Collector 장애 중 metric 유실 허용 범위 | — | 미확인 |

### 범위 밖 수정 (이유)
- `scripts/verify/m1-02.sh` 1줄: Collector 로그 error 검사에서 `Exporting failed` 줄을 제외. 원인: m1-01이 mimir/loki/tempo를 일부러 삭제하는데, F-M1-04부터 backend가 5초마다 metric을 보내서 재시작 구간의 PRW 전송 실패(`context deadline exceeded`, dropped_items 10 × 3건)가 error로 찍혀 `make verify-m1`의 m1-02가 실패했다. 기동/설정 오류 검사는 그대로 유지. 첫 실행(수정 전)은 이 때문에 `verify-m1=2`였다.
- 유의: `make clean && make`(make1/make2=0)는 이 수정 전에 실행했고, verify-m1 통과는 수정 후 같은 클러스터에서 재실행한 결과다. 수정 후 `make clean`부터 다시 돌린 것은 아님.


### 안 된 것
- Grafana UI에서 exemplar 점 클릭 → Tempo → Related logs 클릭 이동은 **미확인** (아래 수동 절차)
- `lgtm_queue_rejected_total`(F-M2-04), `lgtm_output_bytes`(M5)는 범위 밖
- 실제 compile/execute 값이 아니라 stub sleep 기반 duration

### 수동 확인 절차 (VM 브라우저, 1회)
1. VM에서 트래픽: `bash scripts/load.sh -d 120 --interval 1`
2. Firefox `http://grafana.lgtm.local` → Explore → datasource **Mimir** → 쿼리 `histogram_quantile(0.95, sum by (le) (rate(lgtm_execution_duration_seconds_bucket[1m])))`
3. 쿼리 옵션에서 **Exemplars** 켜기 → Run → 그래프의 점(exemplar)에 마우스를 올려 `trace_id` 확인
4. 점의 **Query with Tempo**(trace_id 링크) 클릭 → Tempo trace 열림
5. span(예: `compile`) 클릭 → **Logs for this span** 클릭 → Loki 로그 1줄 이상 확인
(점이 안 보이면 시간 범위를 Last 5 minutes로 좁히고 load.sh가 도는 동안 확인. 스크린샷 1장 남기기)

### 다음 단계
- F-M2-01 compiler-service (rustc → wasm32-wasip1, 별도 pod, traceparent 전파로 backend → rustc span이 한 trace)
- M5 dashboard에서 `load.sh -d`를 트래픽 소스로 사용

## F-M1-03 backend-skeleton (브랜치 feat/m1-03-backend-skeleton)

### 한 일
- `backend/` Go 모듈 `lgtm/backend` (Go **1.27.3**). `cmd/api`(서버, SIGTERM → `http.Server.Shutdown` → provider Shutdown으로 flush), `internal/telemetry`(Tracer/Logger provider, slog fan-out), `internal/execute`(stub). F-M2-01 compiler는 `backend/cmd/compiler`로 같은 모듈에 추가
- `GET /healthz`(계측·로그 없음, Ingress 미노출), `POST /api/execute` stub: compile 20~40ms / execute 10~30ms / ipfs.upload 50~100ms sleep, cid는 `bafy`+코드 sha256 앞 52자의 **가짜 값**. 트리거: `__fail_compile__`(status compile_error), `__slow__`(합계 2~3초). 400 invalid_request(JSON 오류, language≠rust, 빈 code)만 처리. **64KB 413 / 429는 F-M2-04 전까지 없음 → 본문 크기 무제한**
- Tracing: root span 이름은 `execute.RootSpanName`(`"POST /api/execute"`)을 `otelhttp.WithSpanNameFormatter`로 고정. 자식 `compile`(Client) / `execute` / `ipfs.upload`. attribute `code.sha256`, `code.language`, `code.size_bytes`(root), `ipfs.cid`(ipfs.upload + root). 실패 시 해당 span과 root에 `RecordError`(exception event) + `SetStatus(Error)`. W3C TraceContext propagator 등록. OTLP gRPC `otel-collector.observability:4317`(env `OTLP_ENDPOINT`로 변경 가능), `service.name=lgtm-backend`
- Logs: `slog.NewMultiHandler(otelslog, JSON stdout)`. JSON 쪽은 `ctxHandler`가 `trace_id`/`span_id`를 최상위에 넣고, `WithAttrs`/`WithGroup`도 래퍼를 유지(그룹이 열려 있으면 root에 trace attr을 먼저 붙여 재구성). 모든 로그는 `*Context(ctx, …)`. 각 단계 span 안에서 최소 1줄
- 이미지/배포: `backend/Dockerfile`(multi-stage, `RUN --mount=type=cache`로 go mod/build 캐시, non-root 65532). `k8s/app/`(ns `lgtm`, Deployment+Service+Ingress `lgtm.local` `/api` Prefix). `make build` = `scripts/build.sh`(없으면 docker build → `k3d image import`), `make deploy`가 `__BACKEND_IMAGE__` 치환 후 apply + rollout + `scripts/wait-backend.sh`
- `scripts/verify/m1-03.sh` (실패 상태로 먼저 커밋: VM에서 39건 실패)

### 확정 결정과 이유
- **이미지 태그 = 소스 content hash** `lgtm-backend:src-<12자>` (`scripts/image-tag.sh`: `backend/` 전 파일 경로+내용 sha256). VM에 .git이 없고, 시간 태그는 make 재실행마다 이미지가 바뀌어 idempotent 위반. 같은 소스는 같은 태그(build skip, deploy 변화 없음), 소스가 바뀌면 태그가 바뀌어 Deployment가 롤링 교체됨. `:latest` 없음, `imagePullPolicy: IfNotPresent`. 이전 태그는 docker host에서만 정리, **k3d 노드 containerd에는 남음**
- **base 이미지**: 빌드 `golang:1.27.3-trixie`, 런타임 `debian:trixie-20261020-slim`(날짜 태그 고정). F-M2-03에서 wasmtime-go(cgo, glibc 링크)로 바뀔 때 base 교체가 없도록 alpine(musl)/distroless-static을 피하고 VM과 같은 Debian 13 glibc로 맞춤. 지금은 `CGO_ENABLED=0` 정적 빌드
- 6.2 해석: 성공/실패 모두 같은 응답 구조체(모든 필드 항상 포함, `message`만 omitempty). `__fail_compile__`은 compile 실패 → execute 생략 → ipfs.upload 수행 → trace는 span **3개**(성공은 4개)
- 버전 (go.mod에서 확인): otel / sdk / trace / otlptracegrpc **v1.47.0**, otel/log·sdk/log **v1.47.0**, otlploggrpc **v0.23.0**, contrib otelslog **v0.21.0**, otelhttp **v0.72.0**, grpc v1.83.2. 근거 URL: https://go.dev/dl/?mode=json, https://pkg.go.dev/log/slog (`NewMultiHandler`, Go 1.26.0 추가), pkg.go.dev 각 모듈 versions 탭, Docker Hub debian `trixie-20261020-slim`

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 exit 0 | VM 실행 (`make1=0 make2=0`) | 확인(VM) |
| backend pod Ready, request/limit, 이미지 태그 고정, IfNotPresent | `m1-03.sh` | 확인(VM) |
| `POST /api/execute` 200 + 6.2 필드 전부 | `m1-03.sh` | 확인(VM) |
| Tempo: span 4개, root 이름 `POST /api/execute`, 자식 parent=root, TR-03 attribute | `m1-03.sh` | 확인(VM) |
| Loki `{service_name="lgtm-backend"} \| trace_id=` ≥1, 3개 자식 span 각각 `\| span_id=` ≥1 | `m1-03.sh` | 확인(VM) |
| kubectl logs JSON에 같은 trace_id + span_id | `m1-03.sh` | 확인(VM) |
| `__fail_compile__`: compile_error, compile·root ERROR, event 존재, span 3개 | `m1-03.sh` | 확인(VM) |
| `__slow__` 2~3.5초 | `m1-03.sh` | 확인(VM) |
| `lgtm.local /` 와 `/healthz` 본문이 dummy 텍스트 (healthz가 backend로 안 감) | `m1-03.sh` | 확인(VM) |
| m1-01, m1-02 여전히 통과 | `m1-03.sh` 내부 호출 | 확인(VM) |
| 코드 수정 → `make build && make deploy` → 새 태그(`9d3f…`→`55ff…`)로 교체, 응답에 변경 반영, 무변경 재실행은 build skip | VM 실행 | 확인(VM) |
| ctxHandler가 `With`/`WithGroup` 조합에서도 trace_id를 최상위에 유지, MultiHandler fan-out | `go test` 단위 테스트 | 확인(mac 정적). VM 실행 안 함 |
| stub 스키마/span 구성/트리거/400 | `go test` | 확인(mac 정적) |
| Grafana Explore에서 trace → "Logs for this span" 클릭 이동 | — | **미확인** (아래 수동 절차) |
| OTLP exporter 실패(Collector 다운) 시 동작 | — | 미확인 |
| amd64 | — | 미확인 (VM은 aarch64) |

실측: `kubectl top pod -n lgtm` backend 1m / 19Mi (limit 200m/128Mi), 유휴.

### 수동 확인 절차 (VM 브라우저, 1회)
1. Firefox로 `http://grafana.lgtm.local` → Explore → datasource **Tempo** → Query type **TraceQL**(또는 TraceID) → trace ID 입력:
   - 성공 trace: `256307ecde8dcf0cbb06e80f26395ea8`
   - compile_error trace: `22c80413bfa70173357abb2044990bce`
   (없으면 `curl -s -X POST --resolve lgtm.local:80:127.0.0.1 -d '{"language":"rust","code":"fn main(){}"}' http://lgtm.local/api/execute` 로 새로 만들고 응답의 `trace_id` 사용)
2. span 목록에서 `compile` 등 자식 span 클릭 → 상세 패널의 **Logs for this span** 버튼 클릭 → Loki 쿼리 `{service_name=~".+"} | trace_id="…" | span_id="…"` 로 이동하고 로그가 1줄 이상 나오는지 확인
3. compile_error trace에서는 compile / root span이 ERROR로 표시되고 exception event가 보이는지 확인
(m1-02에서 provisioned 쿼리를 Loki API로 직접 실행하는 검증은 통과. 버튼 클릭 자체만 미확인.)

### 안 된 것
- metrics/exemplar (F-M1-04), 실제 compile/실행/IPFS, 413/429 (F-M2-04), compiler pod, frontend
- k3d 노드 containerd의 오래된 `lgtm-backend:src-*` 이미지 정리

### 다음 단계
- **F-M1-04 metrics-exemplar**: `lgtm_execution_duration` histogram + exemplar(trace_id), counter. stub 트리거(`__slow__`, `__fail_compile__`)로 느린/실패 trace 생성. Mimir에 저장된 실제 metric 이름은 조회로 확정. m1-02 HANDOFF의 `service.name → job` label 변환 확인 결과 참고

## F-M1-02 collector-grafana (브랜치 feat/m1-02-collector-grafana)

### 한 일
- `k8s/observability/collector.yaml`: OTel Collector contrib `0.163.1` (Deployment 1, ClusterIP Service 4317/4318, Ingress 없음). receivers otlp(grpc/http), processors memory_limiter+batch, pipelines traces/metrics/logs, `health_check`(13133) → readiness/liveness. limit 500m/256Mi
- exporter 이름은 `otelcol-contrib components`(VM, 0.163.1) 출력으로 확인: `otlp_grpc`(Tempo, `tempo.observability:4317`), `prometheus_remote_write`(Mimir `/api/v1/push`), `otlp_http`(Loki `/otlp`, `/v1/logs` 자동 부착). 구 이름 `otlp`/`otlphttp`/`prometheusremotewrite`는 deprecated alias라 쓰지 않음
- `k8s/observability/grafana.yaml`: Grafana `13.2.4` (Deployment, PVC 없음, limit 500m/512Mi) + Ingress `grafana.lgtm.local` + provisioning ConfigMap 2개(datasources, dashboard provider). `k8s/dummy/grafana.yaml` 삭제
- `make deploy`: Secret `grafana-admin`(없을 때만 랜덤 생성, 출력 안 함) → `dashboards/*.json`으로 ConfigMap `grafana-dashboards`(0개면 빈 것) → apply → rollout 대기 → 기존 클러스터의 `dummy-grafana` 삭제(`apply`는 prune 안 함; 실제로 구 dummy를 apply한 뒤 `make deploy`로 제거됨 확인)
- `scripts/wait-ingress.sh`: `host[/path]` 인자 지원. grafana는 `/api/health` 200 기대
- `scripts/verify/m1-02.sh` (실패 상태로 먼저 커밋: VM에서 28건 실패 확인)
- `scripts/verify/m1-01.sh` 최소 수정: 같은 namespace에 Collector/Grafana가 생겨 "pod 3개", "Ingress 0개" 검사가 깨지므로 `app in (mimir,loki,tempo)` 라벨로 한정, Ingress는 backend 3종을 가리키는 것만 센다 (PRD 변경 아님, 검증 범위 조정)

### 확정 결정과 이유
- Grafana 접근: anonymous **Editor**. Viewer는 Explore 접근이 막혀 trace-to-logs가 깨질 수 있어서. 로그인 폼 숨김. admin은 랜덤 Secret (기본 admin/admin 금지). PRD 14장 해소. admin/admin 으로는 admin API 불가 (verify 확인; 익명 사용자의 정확한 응답 코드는 미확인)
- 외부 통신 차단 (env `GF_<SECTION>_<KEY>`, 13.2.4 `defaults.ini`로 키 존재 확인, 적용값은 `/api/admin/settings`로 verify): analytics.reporting_enabled / check_for_updates / check_for_plugin_updates / feedback_links_enabled=false, news.news_feed_enabled=false, snapshots.external_enabled=false, plugins.preinstall_disabled=true, preinstall_auto_update=false, plugin_admin_enabled=false. (`preinstall_async` 키는 13.2.4에 없음)
- tracesToLogsV2.query: `{service_name=~".+"} | trace_id="$${__trace.traceId}" | span_id="$${__span.spanId}"`. LogQL은 `{...}`로 시작해야 하므로 stream selector 포함. `$$`는 provisioning의 `$` 이스케이프
- tracesToMetrics.tags: `service.name → job`. remote write 변환 후 `service.name`이 `job` label이 됨을 실측으로 확인(아래). queries는 비워둠 (spanmetrics는 F-M5-03)
- Loki derivedFields: `matcherType: label`, `matcherRegex: trace_id` (structured metadata 기준, 로그 본문 regex 아님). provisioning 후 API 응답에 `matcherType: label`이 남는 것 확인
- 근거 URL: https://grafana.com/docs/grafana/v13.2/datasources/tempo/configure-tempo-data-source/ (변수 `${__trace.traceId}`, `${__span.spanId}`), …/configure-tempo-data-source/provision/ (tracesToLogsV2/tracesToMetrics YAML, `$$` 이스케이프), …/datasources/prometheus/configure/ (exemplarTraceIdDestinations), …/datasources/loki/configure/ (derivedFields), …/administration/provisioning/ (dashboard provider). Collector: opentelemetry-collector-contrib v0.163.0 exporter README

### 된 것 (검증표)
| 주장 | 확인 방법 | 결과 |
|---|---|---|
| `make clean && make` exit 0, 재실행 exit 0 | VM에서 실행, 재실행 `MAKE_RERUN_EXIT=0` | 확인(VM) |
| collector/grafana Ready + request/limit | `scripts/verify/m1-02.sh` | 확인(VM) |
| Collector `otelcol-contrib validate` 성공, 기동 로그 error 0 | m1-02 | 확인(VM) |
| `/api/health` 200 (Ingress), 인증 없이 홈 200 / `/api/search` 200 | m1-02 | 확인(VM) |
| admin/admin 불가, Secret 비밀번호로 admin API 200 | m1-02 | 확인(VM) |
| 설정 적용값 (anonymous Editor, 외부 통신 차단 키) | `/api/admin/settings` | 확인(VM) |
| datasource 3개(uid mimir/tempo/loki) 존재 + health OK | Grafana API | 확인(VM) |
| exemplarTraceIdDestinations, tracesToLogsV2(customQuery, span_id), derivedFields(label) | datasource API JSON | 확인(VM) |
| provisioned tracesToLogsV2.query를 trace/span id로 치환해 Loki query_range 실행 → 1건 | m1-02 | 확인(VM) |
| Collector→Tempo / Loki(`\| trace_id=`) / Mimir smoke | m1-02 | 확인(VM) |
| Mimir 저장 label 세트 (service.name=verify-m1-02 로 전송) | `/prometheus/api/v1/series` | 확인(VM): `{__name__="verify_m1_02_gauge", job="verify-m1-02", otel_scope_name="verify"}` |
| Grafana 로그에 외부 다운로드/플러그인 설치 시도 없음 | 로그 grep | 확인(VM) |
| Grafana pod 삭제 후 datasource 3개 유지, PVC 없음 | m1-02 | 확인(VM) |
| m1-01 여전히 통과 | `scripts/verify/m1-01.sh` | 확인(VM) |
| 구 `dummy-grafana`가 있는 클러스터에서 `make deploy`가 제거 | 구 manifest apply 후 deploy | 확인(VM) |
| YAML/스크립트 문법 | `bash -n` (mac) | 확인(mac 정적) |
| metric → trace → logs 클릭 이동, exemplar end-to-end | — | **미확인** (앱 없음, F-M1-04 범위) |
| tracesToMetrics 링크 실제 렌더링 (queries 없음) | — | **미확인** (F-M5-03 spanmetrics 이후) |
| amd64 | — | 미확인 (VM은 aarch64) |

### 실측 (`kubectl top pod -n observability`, VM, 유휴, 재배포 직후 약 1~3분)
| pod | CPU | MEM |
|---|---|---|
| grafana | 8m | 294Mi (limit 512Mi) |
| otel-collector | 8m | 43Mi (limit 256Mi) |
| loki-0 / mimir-0 / tempo-0 | 5m / 5m / 2m | 43Mi / 59Mi / 44Mi |
| node k3d-lgtm-server-0 | 111m (2%) | 1835Mi (23%) |

### 안 된 것
- 클릭 이동(metric→trace→logs) 확인, Collector→Mimir exemplar 전달 실측: F-M1-04
- tracesToMetrics `queries`, serviceMap, nodeGraph: 범위 밖
- dashboard JSON: M5. provider만 설정됨 (`dashboards/` → ConfigMap → `/var/lib/grafana/dashboards`). 새 JSON 추가 후에는 `make deploy`를 다시 실행해야 ConfigMap이 갱신됨

### 다음 단계
- F-M1-03 backend-skeleton
- Collector는 delta metric을 버리므로(prometheus_remote_write 문서) 앱 metric은 cumulative로 export할 것

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
