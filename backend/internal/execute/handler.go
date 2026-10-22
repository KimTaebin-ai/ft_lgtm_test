// Package execute는 POST /api/execute 핸들러다. compile은 compiler 서비스를 호출하고(F-M2-01),
// execute/ipfs.upload는 아직 sleep stub이다 (F-M2-03, F-M3-02에서 교체).
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
)

// RootSpanName은 TR-06: otelhttp 기본값에 의존하지 않고 코드에서 명시한다.
const RootSpanName = "POST /api/execute"

// stub 트리거. __slow__는 execute/ipfs stub의 sleep을 늘려 전체를 2~3초로 만든다 (compile은 실제 시간).
// __fail_compile__ 분기는 없다: compile이 실제 rustc라 문법 오류 코드를 보내면 된다.
const triggerSlow = "__slow__"

// 응답 status. compile_error는 사용자 코드 원인(rustc 에러, compile timeout), internal_error는 플랫폼 원인이다.
// 둘을 나눠야 lgtm_executions{status}와 trace에서 장애와 사용자 오류를 구분할 수 있다 (PRD 6.2 변경).
const (
	statusSuccess       = "success"
	statusCompileError  = "compile_error"
	statusInternalError = "internal_error"
)

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
}

// NewHandler는 root span(RootSpanName)을 만드는 otelhttp 래퍼까지 포함한 http.Handler를 반환한다.
// compilerURL은 compiler의 POST /compile 전체 URL이다.
func NewHandler(log *slog.Logger, tp trace.TracerProvider, m *telemetry.Metrics, compilerURL string) http.Handler {
	h := &handler{log: log, tracer: tp.Tracer("lgtm-backend/execute"), metrics: m, compiler: newCompilerClient(compilerURL)}
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
	slow := strings.Contains(req.Code, triggerSlow)

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
	eSleep, iSleep := stepDurations(slow, time.Duration(resp.TimingsMS.Compile)*time.Millisecond)
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
		// execute (stub). wasm은 F-M2-03에서 Wasmtime에 넘긴다.
		_ = wasm
		resp.TimingsMS.Execute, _ = h.step(ctx, "execute", trace.SpanKindInternal, eSleep, func(ctx context.Context, span trace.Span) error {
			h.log.InfoContext(ctx, "execute started")
			resp.Stdout = "stub output\n"
			h.log.InfoContext(ctx, "execute finished", "stdout_bytes", len(resp.Stdout))
			return nil
		})
	}

	// ipfs.upload: 실패한 실행도 업로드한다 (BE-05)
	resp.CID = fakeCID(sha)
	resp.IPFSURL = "http://ipfs.lgtm.local/ipfs/" + resp.CID
	resp.TimingsMS.IPFSUpload, _ = h.step(ctx, "ipfs.upload", trace.SpanKindInternal, iSleep, func(ctx context.Context, span trace.Span) error {
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

// stepDurations: 평소 execute 10~30ms, ipfs 50~100ms (stub).
// slow면 compile 실제 소요를 포함한 전체가 2~3초가 되도록 남은 시간을 execute/ipfs에 반반 나눈다 (최소 200ms).
func stepDurations(slow bool, compileElapsed time.Duration) (exec, ipfs time.Duration) {
	if slow {
		rest := ms(2000+rand.IntN(1000)) - compileElapsed
		rest = max(rest, ms(200))
		return rest / 2, rest / 2
	}
	return ms(10 + rand.IntN(21)), ms(50 + rand.IntN(51))
}

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
