// Package execute는 POST /api/execute 핸들러다. compile은 compiler 서비스를 호출하고(F-M2-01),
// execute는 wasmtime-go로 실제 실행한다(F-M2-03). ipfs.upload는 아직 sleep stub이다 (F-M3-02에서 교체).
package execute

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

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
	CID       string  `json:"cid"`
	IPFSURL   string  `json:"ipfs_url"`
	TraceID   string  `json:"trace_id"`
	TimingsMS timings `json:"timings_ms"`
}

type handler struct {
	log      *slog.Logger
	tracer   trace.Tracer
	metrics  *telemetry.Metrics
	compiler *compilerClient
	exec     Executor
}

// NewHandler는 root span(RootSpanName)을 만드는 otelhttp 래퍼까지 포함한 http.Handler를 반환한다.
// compilerURL은 compiler의 POST /compile 전체 URL이다.
func NewHandler(log *slog.Logger, tp trace.TracerProvider, m *telemetry.Metrics, compilerURL string, exec Executor) http.Handler {
	h := &handler{log: log, tracer: tp.Tracer("lgtm-backend/execute"), metrics: m, compiler: newCompilerClient(compilerURL), exec: exec}
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

	var req request
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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

	resp := response{Status: statusSuccess, TraceID: root.SpanContext().TraceID().String()}

	// compile: compiler 서비스 호출. step의 span ctx로 호출해야 rustc span의 parent가 compile이 된다.
	var wasm []byte
	var cErr error
	resp.TimingsMS.Compile, cErr = h.step(ctx, "compile", trace.SpanKindClient, 0, func(ctx context.Context, span trace.Span) error {
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
		root.RecordError(cErr)
		root.SetStatus(codes.Error, resp.Message)
	} else {
		h.execute(ctx, root, wasm, &resp)
	}

	// ipfs.upload: 실패한 실행도 업로드한다 (BE-05)
	resp.CID = fakeCID(sha)
	resp.IPFSURL = "http://ipfs.lgtm.local/ipfs/" + resp.CID
	resp.TimingsMS.IPFSUpload, _ = h.step(ctx, "ipfs.upload", trace.SpanKindInternal, ipfsStubDelay(), func(ctx context.Context, span trace.Span) error {
		h.log.InfoContext(ctx, "ipfs upload started")
		span.SetAttributes(attribute.String("ipfs.cid", resp.CID))
		h.log.InfoContext(ctx, "ipfs upload finished", "stub", true)
		return nil
	})
	root.SetAttributes(attribute.String("ipfs.cid", resp.CID))

	h.log.InfoContext(ctx, "execute request done", "status", resp.Status)
	// root span은 otelhttp가 ServeHTTP 반환 뒤에 End한다. 그 전에 root ctx로 기록해야 exemplar에 trace_id가 붙는다.
	h.metrics.RecordExecution(ctx, resp.Status, req.Language, time.Since(start))
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// step은 자식 span 하나를 만들고 d만큼 sleep한 뒤(d가 0이면 생략) fn을 실행한다.
// fn이 error를 반환하면 span을 ERROR로 표시하고 메시지를 event로 남긴다 (TR-02).
func (h *handler) step(ctx context.Context, name string, kind trace.SpanKind, d time.Duration, fn func(context.Context, trace.Span) error) (int64, error) {
	ctx, span := h.tracer.Start(ctx, name, trace.WithSpanKind(kind))
	defer span.End()
	start := time.Now()
	var err error
	if d > 0 {
		err = sleep(ctx, d)
	}
	if err == nil {
		err = fn(ctx, span)
	}
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		h.log.ErrorContext(ctx, name+" failed", "error", err.Error())
	}
	elapsed := time.Since(start)
	// stage span의 ctx로 기록한다 (span.End()는 defer라 이 뒤). span 이름 ipfs.upload → stage label ipfs_upload.
	h.metrics.RecordStage(ctx, strings.ReplaceAll(name, ".", "_"), elapsed)
	return elapsed.Milliseconds(), err
}

func (h *handler) invalid(ctx context.Context, w http.ResponseWriter, msg string) {
	h.log.WarnContext(ctx, "invalid request", "message", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "invalid_request", "message": msg})
}

// ipfsStubDelay: ipfs.upload stub은 50~100ms sleep (F-M3-02에서 실제 업로드로 교체).
func ipfsStubDelay() time.Duration { return ms(50 + rand.IntN(51)) }

func ms(n int) time.Duration { return time.Duration(n) * time.Millisecond }

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// fakeCID는 stub용 가짜 CID다 (코드 sha256 기반, 실제 CID 아님).
func fakeCID(sha string) string { return "bafy" + sha[:52] }

// execFailure는 사용자 코드의 실행 실패(runtime_error/timeout/memory_limit)다. execute span을 ERROR로 만들기 위해
// step의 error로 돌려주지만, 플랫폼 오류(internal_error)와 구분한다.
type execFailure struct{ msg string }

func (e *execFailure) Error() string { return e.msg }

// execute는 execute 단계를 실행해 resp를 채운다. TR-04 attribute(exec.*)는 성공/실패 모두 execute span에 남긴다.
// 실패(success가 아닌 모든 status)면 execute span과 root span을 ERROR로 표시한다.
func (h *handler) execute(ctx context.Context, root trace.Span, wasm []byte, resp *response) {
	var res wasmexec.Result
	var runErr error
	var eErr error
	resp.TimingsMS.Execute, eErr = h.step(ctx, "execute", trace.SpanKindInternal, 0, func(ctx context.Context, span trace.Span) error {
		h.log.InfoContext(ctx, "execute started")
		res, runErr = h.exec.Run(wasm)
		if runErr != nil {
			span.SetAttributes(execAttrs(wasmexec.Result{ExitCode: -1})...)
			return runErr
		}
		span.SetAttributes(execAttrs(res)...)
		h.log.InfoContext(ctx, "execute finished", "status", res.Status, "stdout_bytes", len(res.Stdout), "stderr_bytes", len(res.Stderr), "truncated", res.Truncated)
		if res.Status != wasmexec.StatusSuccess {
			return &execFailure{msg: res.Message}
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
		root.RecordError(eErr)
		root.SetStatus(codes.Error, resp.Message)
	}
}

func execAttrs(res wasmexec.Result) []attribute.KeyValue {
	return []attribute.KeyValue{
		attribute.Int("exec.exit_code", res.ExitCode),
		attribute.Bool("exec.timed_out", res.Status == wasmexec.StatusTimeout),
		attribute.Bool("exec.output_truncated", res.Truncated),
		attribute.Bool("exec.memory_limited", res.Status == wasmexec.StatusMemoryLimit),
	}
}
