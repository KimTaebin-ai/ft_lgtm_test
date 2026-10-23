package compile

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// serveWithSpan은 핸들러를 server span 안에서 실행하고 끝난 span을 돌려준다 (운영에서는 otelhttp가 만드는 rustc span).
func serveWithSpan(t *testing.T, r *Runner, src string) (*httptest.ResponseRecorder, sdktrace.ReadOnlySpan) {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	h := NewHandler(r, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, span := tp.Tracer("t").Start(t.Context(), "rustc", trace.WithSpanKind(trace.SpanKindServer))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/compile", strings.NewReader(src)).WithContext(ctx))
	span.End()
	ended := rec.Ended()
	if len(ended) != 1 {
		t.Fatalf("span %d개", len(ended))
	}
	return w, ended[0]
}

func attrs(s sdktrace.ReadOnlySpan) map[string]any {
	m := map[string]any{}
	for _, a := range s.Attributes() {
		m[string(a.Key)] = a.Value.AsInterface()
	}
	return m
}

// 실패하는 모든 경로에서 status description과 event 가 분류 문구 하나뿐이고 사용자 입력(rustc stderr)이 없다.
func TestRustcSpanClassifiedFailures(t *testing.T) {
	const tok = "uniqident123"
	cases := []struct {
		name, script, src string
		timeout           time.Duration
		class, outcome    string
		exitCode          any // nil 이면 attribute 없음
		header            string
	}{
		{"compile_error", `echo "error[E0425]: cannot find value ` + "`" + tok + "`" + ` in this scope" >&2; exit 1`, `fn main(){}`, time.Second,
			"rustc failed [E0425]", "compile_error", int64(1), "rustc failed [E0425]"},
		{"compile_error_no_code", `echo "error: ` + tok + `" >&2; exit 1`, `fn main(){}`, time.Second,
			"rustc failed", "compile_error", int64(1), "rustc failed"},
		{"timeout", `sleep 60`, `fn main(){}`, 200 * time.Millisecond, "compile timeout", "timeout", nil, ""},
		{"internal", `true`, `fn main(){}`, time.Second, "internal error", "internal", nil, ""},
		{"denied", `exit 1`, `fn main(){ env!("` + tok + `"); }`, time.Second,
			"source denied [deny-env-macro]", "denied", nil, "source denied [deny-env-macro]"},
		{"ok", `printf '\0asm' > out.wasm`, `fn main(){}`, time.Second, "", "ok", int64(0), ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newTestRunner(t, c.script, 2)
			r.Timeout = c.timeout
			w, s := serveWithSpan(t, r, c.src)
			a := attrs(s)
			if a["rustc.outcome"] != c.outcome {
				t.Errorf("rustc.outcome=%v 기대 %s", a["rustc.outcome"], c.outcome)
			}
			if got, ok := a["rustc.exit_code"]; (c.exitCode == nil && ok) || (c.exitCode != nil && got != c.exitCode) {
				t.Errorf("rustc.exit_code=%v 기대 %v", got, c.exitCode)
			}
			if got := w.Header().Get(ClassHeader); got != c.header {
				t.Errorf("%s=%q 기대 %q", ClassHeader, got, c.header)
			}
			if c.class == "" {
				if s.Status().Code == codes.Error || len(s.Events()) != 0 {
					t.Errorf("성공인데 ERROR/event: %v %v", s.Status(), s.Events())
				}
				return
			}
			if s.Status().Code != codes.Error || s.Status().Description != c.class {
				t.Errorf("status=%v 기대 ERROR %q", s.Status(), c.class)
			}
			if len(s.Events()) != 1 || s.Events()[0].Name != "exception" || len(s.Events()[0].Attributes) != 1 ||
				string(s.Events()[0].Attributes[0].Key) != "exception.message" || s.Events()[0].Attributes[0].Value.AsString() != c.class {
				t.Errorf("event=%v 기대 exception.message=%q 하나", s.Events(), c.class)
			}
			for _, kv := range s.Attributes() {
				if strings.Contains(kv.Value.Emit(), tok) {
					t.Errorf("attribute %s 에 사용자 토큰", kv.Key)
				}
			}
		})
	}
}
