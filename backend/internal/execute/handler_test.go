package execute

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func newServer(t *testing.T) (*httptest.Server, *tracetest.SpanRecorder) {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	srv := httptest.NewServer(NewHandler(slog.New(slog.NewTextHandler(io.Discard, nil)), tp))
	t.Cleanup(srv.Close)
	return srv, rec
}

func post(t *testing.T, url, body string) (*http.Response, map[string]any) {
	t.Helper()
	resp, err := http.Post(url, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var m map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&m)
	return resp, m
}

func codeBody(code string) string {
	b, _ := json.Marshal(map[string]string{"language": "rust", "code": code})
	return string(b)
}

func TestSuccessSchemaAndSpans(t *testing.T) {
	srv, rec := newServer(t)
	resp, m := post(t, srv.URL, codeBody(`fn main() {}`))
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	for _, f := range []string{"status", "stdout", "stderr", "truncated", "cid", "ipfs_url", "trace_id", "timings_ms"} {
		if _, ok := m[f]; !ok {
			t.Errorf("필드 %s 없음", f)
		}
	}
	if _, ok := m["message"]; ok {
		t.Error("성공 응답에 message")
	}
	tm, _ := m["timings_ms"].(map[string]any)
	for _, f := range []string{"compile", "execute", "ipfs_upload"} {
		if _, ok := tm[f]; !ok {
			t.Errorf("timings_ms.%s 없음", f)
		}
	}
	if m["status"] != "success" {
		t.Errorf("status=%v", m["status"])
	}
	spans := rec.Ended()
	if len(spans) != 4 {
		t.Fatalf("span %d개", len(spans))
	}
	var root sdktrace.ReadOnlySpan
	for _, s := range spans {
		if !s.Parent().IsValid() {
			root = s
		}
	}
	if root == nil || root.Name() != "POST /api/execute" {
		t.Fatalf("root span 이름 이상: %v", root)
	}
	if root.SpanContext().TraceID().String() != m["trace_id"] {
		t.Error("응답 trace_id 가 root trace 와 다름")
	}
	for _, s := range spans {
		if s != root && s.Parent().SpanID() != root.SpanContext().SpanID() {
			t.Errorf("%s 의 parent 가 root 아님", s.Name())
		}
	}
}

func TestFailCompile(t *testing.T) {
	srv, rec := newServer(t)
	resp, m := post(t, srv.URL, codeBody(`fn main() { /* __fail_compile__ */ }`))
	if resp.StatusCode != 200 || m["status"] != "compile_error" || m["message"] == "" {
		t.Fatalf("응답 이상: %d %v", resp.StatusCode, m)
	}
	names := map[string]sdktrace.ReadOnlySpan{}
	for _, s := range rec.Ended() {
		names[s.Name()] = s
	}
	if len(names) != 3 || names["execute"] != nil {
		t.Fatalf("span 구성 이상: %v", names)
	}
	for _, n := range []string{"compile", "POST /api/execute"} {
		s := names[n]
		if s.Status().Code.String() != "Error" || len(s.Events()) == 0 {
			t.Errorf("%s: status=%v events=%d", n, s.Status().Code, len(s.Events()))
		}
	}
}

func TestSlow(t *testing.T) {
	srv, _ := newServer(t)
	t0 := time.Now()
	post(t, srv.URL, codeBody(`fn main() { /* __slow__ */ }`))
	if d := time.Since(t0); d < 2*time.Second || d > 3500*time.Millisecond {
		t.Errorf("소요 %v", d)
	}
}

func TestInvalid(t *testing.T) {
	srv, _ := newServer(t)
	for _, body := range []string{`{`, `{"language":"go","code":"x"}`, `{"language":"rust","code":" "}`} {
		resp, m := post(t, srv.URL, body)
		if resp.StatusCode != 400 || m["status"] != "invalid_request" {
			t.Errorf("%s → %d %v", body, resp.StatusCode, m)
		}
	}
}
