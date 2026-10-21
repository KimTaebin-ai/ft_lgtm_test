// Package execute는 POST /api/execute stub이다. compile/execute/ipfs.upload를 sleep으로 흉내 낸다.
// F-M2-01, F-M2-03에서 실제 구현으로 교체된다.
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
)

// RootSpanName은 TR-06: otelhttp 기본값에 의존하지 않고 코드에서 명시한다.
const RootSpanName = "POST /api/execute"

// stub 트리거 (F-M1-04 exemplar 테스트, frontend 개발용)
const (
	triggerFailCompile = "__fail_compile__"
	triggerSlow        = "__slow__"
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
	log    *slog.Logger
	tracer trace.Tracer
}

// NewHandler는 root span(RootSpanName)을 만드는 otelhttp 래퍼까지 포함한 http.Handler를 반환한다.
func NewHandler(log *slog.Logger, tp trace.TracerProvider) http.Handler {
	h := &handler{log: log, tracer: tp.Tracer("lgtm-backend/execute")}
	return otelhttp.NewHandler(h, RootSpanName,
		otelhttp.WithTracerProvider(tp),
		otelhttp.WithPropagators(propagation.TraceContext{}),
		otelhttp.WithSpanNameFormatter(func(string, *http.Request) string { return RootSpanName }),
	)
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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

	resp := response{Status: "success", TraceID: root.SpanContext().TraceID().String()}
	cSleep, eSleep, iSleep := stepDurations(strings.Contains(req.Code, triggerSlow))

	// compile
	var cErr error
	resp.TimingsMS.Compile, cErr = h.step(ctx, "compile", trace.SpanKindClient, cSleep, func(ctx context.Context, _ trace.Span) error {
		h.log.InfoContext(ctx, "compile started")
		if strings.Contains(req.Code, triggerFailCompile) {
			return errors.New("stub: error[E0425]: cannot find value `__fail_compile__` in this scope")
		}
		h.log.InfoContext(ctx, "compile finished")
		return nil
	})
	if cErr != nil {
		resp.Status = "compile_error"
		resp.Message = cErr.Error()
		resp.Stderr = cErr.Error() + "\n"
		root.RecordError(cErr)
		root.SetStatus(codes.Error, cErr.Error())
	} else {
		// execute
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
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// step은 자식 span 하나를 만들고 d만큼 sleep한 뒤 fn을 실행한다.
// fn이 error를 반환하면 span을 ERROR로 표시하고 메시지를 event로 남긴다 (TR-02).
func (h *handler) step(ctx context.Context, name string, kind trace.SpanKind, d time.Duration, fn func(context.Context, trace.Span) error) (int64, error) {
	ctx, span := h.tracer.Start(ctx, name, trace.WithSpanKind(kind))
	defer span.End()
	start := time.Now()
	err := sleep(ctx, d)
	if err == nil {
		err = fn(ctx, span)
	}
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		h.log.ErrorContext(ctx, name+" failed", "error", err.Error())
	}
	return time.Since(start).Milliseconds(), err
}

func (h *handler) invalid(ctx context.Context, w http.ResponseWriter, msg string) {
	h.log.WarnContext(ctx, "invalid request", "message", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "invalid_request", "message": msg})
}

// stepDurations: 평소 compile 20~40ms, execute 10~30ms, ipfs 50~100ms. slow면 합계 2~3초.
func stepDurations(slow bool) (compile, exec, ipfs time.Duration) {
	if slow {
		total := 2000 + rand.IntN(1000)
		return ms(total * 4 / 10), ms(total * 3 / 10), ms(total * 3 / 10)
	}
	return ms(20 + rand.IntN(21)), ms(10 + rand.IntN(21)), ms(50 + rand.IntN(51))
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
