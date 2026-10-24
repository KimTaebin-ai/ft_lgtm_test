// Package execute는 POST /api/execute 핸들러다. compile은 compiler 서비스를 호출하고(F-M2-01),
// execute는 wasmtime-go로 실제 실행하고(F-M2-03), 결과는 Kubo로 디렉토리 업로드한다(F-M3-02).
package execute

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"lgtm/backend/internal/ipfs"
	"lgtm/backend/internal/limiter"
	"lgtm/backend/internal/telemetry"
	"lgtm/backend/internal/wasmexec"
)

// RootSpanName은 TR-06: otelhttp 기본값에 의존하지 않고 코드에서 명시한다.
const RootSpanName = "POST /api/execute"

// 응답 status. compile_error는 사용자 코드 원인(rustc 에러, compile timeout), internal_error는 플랫폼 원인이다.
// 둘을 나눠야 lgtm_executions{status}와 trace에서 장애와 사용자 오류를 구분할 수 있다 (PRD 6.2 변경).
const (
	statusSuccess       = "success"
	statusCompileError  = "compile_error"
	statusInternalError = "internal_error"
)

const (
	// maxBodyBytes는 요청 body 상한이다 (PRD BE-01, SEC-06). JSON 래핑을 포함한 body 전체 기준.
	maxBodyBytes = 64 * 1024

	// 동시 처리 2 + 대기 8 (PRD BE-09, SEC-07, SEC-08). 큐 범위는 compile + execute + ipfs.upload 전체다.
	maxActive  = 2
	maxWaiting = 8
	// maxQueueWait는 대기 상한 시간이다. 최악 대기 = 앞 8개 × 요청 1건 소요 / 2. 슬롯은 ipfs.upload가 끝날 때까지 점유된다.
	// 정상 최악(loop {}: compile 0.25s + execute 5.1s + ipfs 업로드 0.1~0.2s ≈ 5.5s)이면 8×5.5/2 ≈ 22s.
	// Kubo가 응답하지 않으면(업로드 10초 timeout) 짧은 코드도 슬롯을 약 10.3s 점유한다: 8×10.3/2 ≈ 41s < 45s라 대기열이 429로 잘리지 않고 처리된다.
	// 단 loop {} 요청이 몰리고 Kubo까지 죽은 최악 조합(0.25+5.1+10 ≈ 15.4s)은 8×15.4/2 ≈ 61s > 45s라 초과분은 429다.
	// 이론 최악(compile 15s + execute 5s + ipfs 10s)은 8×30/2 = 120s라 사용자가 기다릴 수 없으므로,
	// 정상 최악의 약 2배인 45초에서 429로 돌려보낸다. 무한 대기는 전부 timeout이 되므로 금지 (SEC-08).
	maxQueueWait = 45 * time.Second
)

// ipfsUploadTimeout은 Kubo add + pin 상한이다 (PRD BE-10, SEC-11). 초과하면 결과는 그대로 반환하고 cid는 null이다.
// 테스트가 짧게 바꿔 timeout 경로를 빠르게 확인할 수 있도록 var로 둔다 (운영 코드는 바꾸지 않는다).
var ipfsUploadTimeout = 10 * time.Second

// ipfsGatewayURL은 응답 ipfs_url의 앞부분이다. Ingress로 노출한 Kubo gateway host다 (F-M3-03).
const ipfsGatewayURL = "http://ipfs.lgtm.local/ipfs/"

// InitMetrics는 lgtm_executions의 모든 status series와 lgtm_queue_rejected를 0으로 시작시킨다 (운영 기동 시 1회).
func InitMetrics(m *telemetry.Metrics) {
	m.InitSeries("rust", []string{statusSuccess, statusCompileError, statusInternalError,
		wasmexec.StatusRuntimeError, wasmexec.StatusTimeout, wasmexec.StatusMemoryLimit})
}

// NewLimiter는 PRD 기준(처리 2 + 대기 8, 대기 상한 45초)의 Limiter를 만든다.
func NewLimiter() *limiter.Limiter { return limiter.New(maxActive, maxWaiting, maxQueueWait) }

// Uploader는 파일들을 IPFS 디렉토리로 올리고 CID를 돌려준다. 운영에서는 *ipfs.Client, 테스트에서는 가짜를 넣는다.
type Uploader interface {
	AddDir(ctx context.Context, files []ipfs.File) (string, error)
}

// Executor는 wasm 하나를 실행한다. 운영에서는 *wasmexec.Runner, 테스트에서는 가짜를 넣는다.
type Executor interface {
	Run(wasm []byte) (wasmexec.Result, error)
}

type request struct {
	Language string `json:"language"`
	Code     string `json:"code"`
}

type timings struct {
	Compile    int64 `json:"compile"`
	Execute    int64 `json:"execute"`
	IPFSUpload int64 `json:"ipfs_upload"`
}

// response는 PRD 6.2 스키마. 성공/실패 모두 같은 구조체를 쓰고 message만 생략 가능하다.
type response struct {
	Status    string  `json:"status"`
	Message   string  `json:"message,omitempty"`
	Stdout    string  `json:"stdout"`
	Stderr    string  `json:"stderr"`
	Truncated bool    `json:"truncated"`
	CID       *string `json:"cid"`      // 업로드 실패/timeout이면 null
	IPFSURL   *string `json:"ipfs_url"` // 업로드 실패/timeout이면 null
	TraceID   string  `json:"trace_id"`
	TimingsMS timings `json:"timings_ms"`
}

type handler struct {
	log      *slog.Logger
	tracer   trace.Tracer
	metrics  *telemetry.Metrics
	compiler *compilerClient
	exec     Executor
	up       Uploader
	lim      *limiter.Limiter
}

// NewHandler는 root span(RootSpanName)을 만드는 otelhttp 래퍼까지 포함한 http.Handler를 반환한다.
// compilerURL은 compiler의 POST /compile 전체 URL이다.
func NewHandler(log *slog.Logger, tp trace.TracerProvider, m *telemetry.Metrics, compilerURL string, exec Executor, up Uploader, lim *limiter.Limiter) http.Handler {
	h := &handler{log: log, tracer: tp.Tracer("lgtm-backend/execute"), metrics: m, compiler: newCompilerClient(compilerURL), exec: exec, up: up, lim: lim}
	if err := m.RegisterQueueGauges(lim.Active, lim.Waiting); err != nil {
		log.Error("queue gauge 등록 실패", "error", err.Error())
	}
	return otelhttp.NewHandler(h, RootSpanName,
		otelhttp.WithTracerProvider(tp),
		otelhttp.WithPropagators(propagation.TraceContext{}),
		otelhttp.WithSpanNameFormatter(func(string, *http.Request) string { return RootSpanName }),
	)
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	ctx := r.Context()
	root := trace.SpanFromContext(ctx)

	// 413: Content-Length가 크면 본문을 읽지 않고 거부하고, 아니면 MaxBytesReader로 읽는 양 자체를 제한한다.
	if r.ContentLength > maxBodyBytes {
		h.tooLarge(ctx, w, root)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	var req request
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			h.tooLarge(ctx, w, root)
			return
		}
		h.invalid(ctx, w, "요청 본문이 올바른 JSON이 아닙니다")
		return
	}
	if req.Language != "rust" || strings.TrimSpace(req.Code) == "" {
		h.invalid(ctx, w, `language는 "rust", code는 비어 있지 않아야 합니다`)
		return
	}

	sum := sha256.Sum256([]byte(req.Code))
	sha := hex.EncodeToString(sum[:])
	root.SetAttributes(
		attribute.String("code.sha256", sha),
		attribute.String("code.language", req.Language),
		attribute.Int("code.size_bytes", len(req.Code)),
	)
	h.log.InfoContext(ctx, "execute request received", "code_size_bytes", len(req.Code))

	// 큐: 400/413은 슬롯을 쓰지 않는다. 가득 차면 즉시 429, 대기 중 클라이언트가 끊으면 자리가 반환된다.
	release, qwait, qerr := h.lim.Acquire(ctx)
	if qerr != nil {
		h.queueRejected(ctx, w, root, qerr)
		return
	}
	defer release()
	root.SetAttributes(attribute.Int64("queue.wait_ms", qwait.Milliseconds()))
	// 대기 0도 기록한다. execution_duration은 큐 대기를 포함하므로 stage로 나눠야 지연 원인을 구분할 수 있다.
	h.metrics.RecordStage(ctx, "queue", qwait)

	resp := response{Status: statusSuccess, TraceID: root.SpanContext().TraceID().String()}
	var exitCode *int // 실행 전에 끝난 요청(compile 실패 등)은 nil → status.json 의 exit_code: null

	// compile: compiler 서비스 호출. step의 span ctx로 호출해야 rustc span의 parent가 compile이 된다.
	var wasm []byte
	var cErr error
	resp.TimingsMS.Compile, cErr = h.step(ctx, "compile", trace.SpanKindClient, func(ctx context.Context, span trace.Span) error {
		var err error
		h.log.InfoContext(ctx, "compile started")
		wasm, err = h.compiler.compile(ctx, req.Code)
		if err == nil {
			span.SetAttributes(attribute.Int("wasm.size_bytes", len(wasm)))
			h.log.InfoContext(ctx, "compile finished", "wasm_bytes", len(wasm))
		}
		return err
	})
	if cErr != nil {
		var ue *userError
		if errors.As(cErr, &ue) {
			resp.Status = statusCompileError
			resp.Message = ue.Message
			resp.Stderr = ue.Stderr
		} else {
			resp.Status = statusInternalError
			resp.Message = "internal error: " + cErr.Error()
		}
		cls, _ := failClass(cErr, "compile")
		telemetry.FailSpan(root, cls)
	} else {
		exitCode = h.execute(ctx, root, wasm, &resp)
	}

	// ipfs.upload: 실패한 실행도 업로드한다 (BE-05). 업로드 실패/timeout은 부분 실패다: ipfs.upload span만 ERROR로 두고
	// 응답 status와 root span은 실행 결과 그대로 유지하며 cid/ipfs_url은 null이다 (BE-10). 코드 원문은 로그에 남기지 않는다.
	files := buildFiles(req.Code, resp, exitCode)
	var cid string
	var uErr error
	resp.TimingsMS.IPFSUpload, uErr = h.step(ctx, "ipfs.upload", trace.SpanKindInternal, func(ctx context.Context, span trace.Span) error {
		uctx, cancel := context.WithTimeout(ctx, ipfsUploadTimeout)
		defer cancel()
		h.log.InfoContext(ctx, "ipfs upload started", "files", len(files))
		c, err := h.up.AddDir(uctx, files)
		if err != nil {
			return &uploadError{err: err}
		}
		cid = c
		span.SetAttributes(attribute.String("ipfs.cid", cid))
		h.log.InfoContext(ctx, "ipfs upload finished", "cid", cid)
		return nil
	})
	if uErr == nil {
		url := ipfsGatewayURL + cid + "/"
		resp.CID, resp.IPFSURL = &cid, &url
		root.SetAttributes(attribute.String("ipfs.cid", cid))
	}
	release() // 응답 쓰기 전에 슬롯 반환 (느린 클라이언트가 슬롯을 쥐지 않게)

	h.log.InfoContext(ctx, "execute request done", "status", resp.Status)
	root.SetAttributes(attribute.String("lgtm.status", resp.Status))
	// root span은 otelhttp가 ServeHTTP 반환 뒤에 End한다. 그 전에 root ctx로 기록해야 exemplar에 trace_id가 붙는다.
	h.metrics.RecordExecution(ctx, resp.Status, req.Language, time.Since(start))
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// step은 자식 span 하나를 만들고 fn을 실행한다.
// fn이 error를 반환하면 span을 ERROR로 표시하고 분류형 문구를 event로 남긴다 (TR-02).
// span/event/로그에는 err.Error()를 쓰지 않는다. 사용자 입력(rustc 메시지, panic 메시지)이 섞여 있을 수 있기 때문이다.
func (h *handler) step(ctx context.Context, name string, kind trace.SpanKind, fn func(context.Context, trace.Span) error) (int64, error) {
	ctx, span := h.tracer.Start(ctx, name, trace.WithSpanKind(kind))
	defer span.End()
	start := time.Now()
	err := fn(ctx, span)
	if err != nil {
		cls, userDerived := failClass(err, name)
		telemetry.FailSpan(span, cls)
		if userDerived {
			h.log.ErrorContext(ctx, name+" failed", "class", cls)
		} else {
			// 플랫폼 오류(Kubo 응답, 연결 실패 등)는 사용자 입력이 아니므로 원인을 로그에 남긴다.
			h.log.ErrorContext(ctx, name+" failed", "class", cls, "error", err.Error())
		}
	}
	elapsed := time.Since(start)
	// stage span의 ctx로 기록한다 (span.End()는 defer라 이 뒤). span 이름 ipfs.upload → stage label ipfs_upload.
	h.metrics.RecordStage(ctx, strings.ReplaceAll(name, ".", "_"), elapsed)
	return elapsed.Milliseconds(), err
}

func (h *handler) invalid(ctx context.Context, w http.ResponseWriter, msg string) {
	trace.SpanFromContext(ctx).SetAttributes(attribute.String("lgtm.status", "invalid_request"))
	h.log.WarnContext(ctx, "invalid request", "message", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "invalid_request", "message": msg})
}

func (h *handler) tooLarge(ctx context.Context, w http.ResponseWriter, root trace.Span) {
	h.log.WarnContext(ctx, "request rejected", "reason", "payload_too_large", "limit_bytes", maxBodyBytes)
	root.SetAttributes(attribute.Bool("request.too_large", true), attribute.String("lgtm.status", "payload_too_large"))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close") // 남은 본문을 읽지 않고 연결을 닫는다
	w.WriteHeader(http.StatusRequestEntityTooLarge)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "payload_too_large", "message": "요청 본문은 64KB 이하여야 합니다"})
}

// queueRejected는 Acquire 실패를 처리한다. 429(가득 참/대기 상한)는 lgtm_queue_rejected_total만 올리고
// lgtm_executions에는 넣지 않는다 (실행이 시작되지 않은 요청). 클라이언트가 끊은 경우는 응답을 쓰지 않는다.
func (h *handler) queueRejected(ctx context.Context, w http.ResponseWriter, root trace.Span, err error) {
	if !errors.Is(err, limiter.ErrFull) && !errors.Is(err, limiter.ErrWaitTimeout) {
		root.SetAttributes(attribute.Bool("queue.cancelled", true))
		h.log.InfoContext(ctx, "queue wait cancelled", "reason", err.Error())
		return
	}
	reason := "full"
	if errors.Is(err, limiter.ErrWaitTimeout) {
		reason = "wait_timeout"
	}
	root.SetAttributes(attribute.Bool("queue.rejected", true), attribute.String("queue.reason", reason), attribute.String("lgtm.status", "queue_full"))
	h.log.WarnContext(ctx, "request rejected", "reason", "queue_"+reason, "active", h.lim.Active(), "waiting", h.lim.Waiting())
	h.metrics.RecordQueueRejected(ctx)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusTooManyRequests)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "queue_full", "message": "서버가 바쁩니다. 잠시 후 다시 시도하세요", "trace_id": root.SpanContext().TraceID().String()})
}

// execute는 execute 단계를 실행해 resp를 채우고 종료 코드(실행 결과가 없으면 nil)를 돌려준다. TR-04 attribute(exec.*)는 성공/실패 모두 execute span에 남긴다.
// 실패(success가 아닌 모든 status)면 execute span과 root span을 ERROR로 표시한다.
func (h *handler) execute(ctx context.Context, root trace.Span, wasm []byte, resp *response) *int {
	rootCtx := ctx
	var res wasmexec.Result
	var runErr error
	var eErr error
	resp.TimingsMS.Execute, eErr = h.step(ctx, "execute", trace.SpanKindInternal, func(ctx context.Context, span trace.Span) error {
		h.log.InfoContext(ctx, "execute started")
		res, runErr = h.exec.Run(wasm)
		if runErr != nil {
			span.SetAttributes(execAttrs(wasmexec.Result{ExitCode: -1})...)
			return runErr
		}
		span.SetAttributes(execAttrs(res)...)
		h.log.InfoContext(ctx, "execute finished", "status", res.Status, "stdout_bytes", len(res.Stdout), "stderr_bytes", len(res.Stderr), "truncated", res.Truncated)
		// 출력 크기는 실행이 끝난 요청만 기록한다. root ctx로 기록해야 exemplar에 root trace_id가 붙는다.
		h.metrics.RecordOutput(rootCtx, len(res.Stdout)+len(res.Stderr))
		if res.Status != wasmexec.StatusSuccess {
			return &execFailure{msg: res.Message, class: res.Class}
		}
		return nil
	})
	switch {
	case runErr != nil:
		resp.Status = statusInternalError
		resp.Message = "internal error: " + runErr.Error()
	default:
		resp.Status = res.Status
		resp.Stdout, resp.Stderr, resp.Truncated = res.Stdout, res.Stderr, res.Truncated
		if res.Status != wasmexec.StatusSuccess {
			resp.Message = res.Message
		}
	}
	if eErr != nil {
		cls, _ := failClass(eErr, "execute")
		telemetry.FailSpan(root, cls)
	}
	if runErr != nil {
		return nil // 실행기가 결과를 못 냈으므로 종료 코드 없음
	}
	return &res.ExitCode
}

func execAttrs(res wasmexec.Result) []attribute.KeyValue {
	return []attribute.KeyValue{
		attribute.Int("exec.exit_code", res.ExitCode),
		attribute.Bool("exec.timed_out", res.Status == wasmexec.StatusTimeout),
		attribute.Bool("exec.output_truncated", res.Truncated),
		attribute.Bool("exec.memory_limited", res.Status == wasmexec.StatusMemoryLimit),
	}
}
