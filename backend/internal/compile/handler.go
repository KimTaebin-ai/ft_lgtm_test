package compile

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"lgtm/backend/internal/telemetry"
)

// MaxSourceBytes는 compiler가 받는 소스 상한. 413/요청 크기 정책은 F-M2-04 범위라 여기서는 400으로만 거부한다.
const MaxSourceBytes = 1 << 20

// ClassHeader는 422 응답에 붙는 분류형 문구다. backend가 span/event/로그에 쓴다.
// 사용자 입력(rustc 메시지의 식별자)이 없는 고정 문구만 담는다.
const ClassHeader = "X-Lgtm-Class"

// rustc.outcome 값
const (
	outcomeOK       = "ok"
	outcomeCompile  = "compile_error"
	outcomeDenied   = "denied"
	outcomeTimeout  = "timeout"
	outcomeCanceled = "canceled"
	outcomeInternal = "internal"
)

var errorCodeRe = regexp.MustCompile(`(?m)^error\[(E[0-9]{4})\]`)

// rustcClass는 rustc 실패의 분류 문구다. 에러 코드(E0425)만 꺼내고 나머지 메시지는 쓰지 않는다.
func rustcClass(stderr string) string {
	if m := errorCodeRe.FindStringSubmatch(stderr); m != nil {
		return "rustc failed [" + m[1] + "]"
	}
	return "rustc failed"
}

// NewHandler는 POST /compile 핸들러다. 소스는 text/plain 본문.
// 200: wasm 바이트 / 422: rustc stderr / 504: timeout / 500: 내부 오류.
// 바깥(cmd/compiler)에서 otelhttp로 감싸 server span "rustc"를 만든다. 이 핸들러는 그 span에 속성/상태만 기록한다.
func NewHandler(r *Runner, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		ctx := req.Context()
		span := trace.SpanFromContext(ctx)

		src, err := io.ReadAll(http.MaxBytesReader(w, req.Body, MaxSourceBytes))
		if err != nil || len(src) == 0 {
			http.Error(w, "소스 본문이 비었거나 너무 큽니다", http.StatusBadRequest)
			return
		}
		span.SetAttributes(attribute.Int("code.size_bytes", len(src)))

		// rustc 실행 전 소스 deny-list (F-M2-02). 위반은 사용자 코드 오류라 422다.
		if v := CheckSource(string(src)); v != nil {
			class := "source denied [" + v.Rule + "]"
			telemetry.FailSpan(span, class)
			span.SetAttributes(attribute.String("denylist.rule", v.Rule), attribute.String("rustc.outcome", outcomeDenied))
			log.WarnContext(ctx, "source denied", "rule", v.Rule, "line", v.Line)
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.Header().Set(ClassHeader, class)
			w.WriteHeader(http.StatusUnprocessableEntity)
			_, _ = io.WriteString(w, v.Message())
			return
		}

		wasm, wait, err := r.Run(ctx, src)
		span.SetAttributes(attribute.Int64("compile.queue_wait_ms", wait.Milliseconds()))

		var ce *CompileError
		switch {
		case err == nil:
			span.SetAttributes(attribute.Int("wasm.size_bytes", len(wasm)),
				attribute.String("rustc.outcome", outcomeOK), attribute.Int("rustc.exit_code", 0))
			w.Header().Set("Content-Type", "application/wasm")
			w.Header().Set("Content-Length", strconv.Itoa(len(wasm)))
			_, _ = w.Write(wasm)
		case errors.As(err, &ce):
			class := rustcClass(ce.Stderr)
			telemetry.FailSpan(span, class)
			span.SetAttributes(attribute.String("rustc.outcome", outcomeCompile), attribute.Int("rustc.exit_code", ce.ExitCode))
			// http.Error는 개행을 덧붙이므로 stderr는 그대로 쓴다.
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.Header().Set(ClassHeader, class)
			w.WriteHeader(http.StatusUnprocessableEntity)
			_, _ = io.WriteString(w, ce.Stderr)
		case errors.Is(err, ErrTimeout):
			telemetry.FailSpan(span, "compile timeout")
			span.SetAttributes(attribute.String("rustc.outcome", outcomeTimeout))
			log.WarnContext(ctx, "compile timeout", "timeout", r.Timeout.String())
			http.Error(w, "compile timeout ("+r.Timeout.String()+")", http.StatusGatewayTimeout)
		case ctx.Err() != nil:
			// 클라이언트가 끊었다. 응답할 곳이 없다.
			telemetry.FailSpan(span, "request canceled")
			span.SetAttributes(attribute.String("rustc.outcome", outcomeCanceled))
		default:
			telemetry.FailSpan(span, "internal error")
			span.SetAttributes(attribute.String("rustc.outcome", outcomeInternal))
			log.ErrorContext(ctx, "compile internal error", "error", err.Error())
			http.Error(w, "internal error", http.StatusInternalServerError)
		}
	})
}
