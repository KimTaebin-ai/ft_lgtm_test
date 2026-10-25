package execute

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"go.opentelemetry.io/otel/codes"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"lgtm/backend/internal/ipfs"
	"lgtm/backend/internal/telemetry"
	"lgtm/backend/internal/wasmexec"
)

const userTok = "uniqusertok99"

type logBuf struct{ bytes.Buffer }

// newCaptureServer 는 로그를 버퍼로 모으는 서버를 만든다.
func newCaptureServer(t *testing.T, compilerURL string, ex Executor, up Uploader) (*httptest.Server, *tracetest.SpanRecorder, *sdkmetric.ManualReader, *logBuf) {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	reader := sdkmetric.NewManualReader()
	m, err := telemetry.NewMetrics(sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader)))
	if err != nil {
		t.Fatal(err)
	}
	lb := &logBuf{}
	srv := httptest.NewServer(NewHandler(slog.New(slog.NewTextHandler(lb, nil)), tp, m, compilerURL, ex, up, NewLimiter()))
	t.Cleanup(srv.Close)
	return srv, rec, reader, lb
}

func rustcFail(header string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if header != "" {
			w.Header().Set("X-Lgtm-Class", header)
		}
		http.Error(w, "error[E0425]: cannot find value `"+userTok+"` in this scope\n", http.StatusUnprocessableEntity)
	}
}

// 모든 실패 status 에서 span status/event/attribute/로그에 사용자 입력이 없고, 분류 문구와 lgtm.status 가 기대대로다.
func TestFailureClassesHaveNoUserStrings(t *testing.T) {
	cases := []struct {
		name     string
		compiler http.HandlerFunc
		ex       *fakeExec
		up       *fakeUploader
		status   string
		class    string   // root/실패 단계 span 의 문구
		errSpans []string // ERROR 여야 하는 span
	}{
		{"compile_error", rustcFail("rustc failed [E0425]"), nil, nil, "compile_error", "rustc failed [E0425]", []string{"POST /api/execute", "compile"}},
		{"compile_error_spoofed_header", rustcFail("rustc failed [" + userTok + " x]"), nil, nil, "compile_error", "rustc failed", []string{"POST /api/execute", "compile"}},
		{"compile_error_other_header", rustcFail(userTok), nil, nil, "compile_error", "rustc failed", []string{"POST /api/execute", "compile"}},
		{"compile_internal", func(w http.ResponseWriter, _ *http.Request) { http.Error(w, userTok, 500) }, nil, nil, "internal_error", "internal error [compile]", []string{"POST /api/execute", "compile"}},
		{"runtime_trap", nil, &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusRuntimeError, Message: "trap: " + userTok, Class: "wasm trap [unreachable]", ExitCode: -1}}, nil,
			"runtime_error", "wasm trap [unreachable]", []string{"POST /api/execute", "execute"}},
		{"runtime_exit", nil, &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusRuntimeError, Message: "exit status 101", Class: "exit code 101", ExitCode: 101}}, nil,
			"runtime_error", "exit code 101", []string{"POST /api/execute", "execute"}},
		{"timeout", nil, &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusTimeout, Message: "time limit exceeded (5s)", Class: "time limit exceeded", ExitCode: -1}}, nil,
			"timeout", "time limit exceeded", []string{"POST /api/execute", "execute"}},
		{"memory_limit", nil, &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusMemoryLimit, Message: "memory limit exceeded", Class: "memory limit exceeded", ExitCode: -1}}, nil,
			"memory_limit", "memory limit exceeded", []string{"POST /api/execute", "execute"}},
		{"executor_internal", nil, &fakeExec{err: errors.New("engine failure")}, nil, "internal_error", "internal error [execute]", []string{"POST /api/execute", "execute"}},
		// 업로드 실패는 ipfs.upload 만 ERROR
		{"upload_5xx", nil, nil, &fakeUploader{err: &ipfs.StatusError{Code: 503, Body: "kubo"}}, "success", "ipfs upload failed [http_5xx]", []string{"ipfs.upload"}},
		{"upload_4xx", nil, nil, &fakeUploader{err: &ipfs.StatusError{Code: 400, Body: "kubo"}}, "success", "ipfs upload failed [http_4xx]", []string{"ipfs.upload"}},
		{"upload_timeout", nil, nil, &fakeUploader{err: context.DeadlineExceeded}, "success", "ipfs upload failed [timeout]", []string{"ipfs.upload"}},
		{"upload_other", nil, nil, &fakeUploader{err: errors.New("x")}, "success", "ipfs upload failed [other]", []string{"ipfs.upload"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var ex Executor = okExec()
			if c.ex != nil {
				ex = c.ex
			}
			var up Uploader = &fakeUploader{}
			if c.up != nil {
				up = c.up
			}
			srv, rec, _, lb := newCaptureServer(t, newFakeCompiler(t, c.compiler).srv.URL, ex, up)
			_, m := post(t, srv.URL, codeBody(`fn main() { /* `+userTok+` */ }`))
			if m["status"] != c.status {
				t.Fatalf("status=%v 기대 %s (%v)", m["status"], c.status, m)
			}
			var errs []string
			var root sdktrace.ReadOnlySpan
			for _, s := range rec.Ended() {
				if !s.Parent().IsValid() {
					root = s
				}
				if s.Status().Code == codes.Error {
					errs = append(errs, s.Name())
					if s.Status().Description != c.class {
						t.Errorf("%s status description=%q 기대 %q", s.Name(), s.Status().Description, c.class)
					}
					if len(s.Events()) != 1 || s.Events()[0].Name != "exception" || len(s.Events()[0].Attributes) != 1 ||
						string(s.Events()[0].Attributes[0].Key) != "exception.message" {
						t.Errorf("%s event=%v (exception.message 하나여야 함)", s.Name(), s.Events())
					} else if got := s.Events()[0].Attributes[0].Value.AsString(); got != c.class || len(got) > telemetry.MaxSpanMessageBytes {
						t.Errorf("%s event message=%q 기대 %q", s.Name(), got, c.class)
					}
				}
				for _, kv := range s.Attributes() {
					if strings.Contains(kv.Value.Emit(), userTok) {
						t.Errorf("%s attribute %s 에 사용자 문자열", s.Name(), kv.Key)
					}
				}
			}
			if !sameSet(errs, c.errSpans) {
				t.Errorf("ERROR span=%v 기대 %v", errs, c.errSpans)
			}
			if root == nil || attrOf(root, "lgtm.status") != c.status {
				t.Errorf("root lgtm.status=%v 기대 %s", attrOf(root, "lgtm.status"), c.status)
			}
			if strings.Contains(lb.String(), userTok) {
				t.Errorf("로그에 사용자 문자열:\n%s", lb.String())
			}
		})
	}
}

func attrOf(s sdktrace.ReadOnlySpan, key string) any {
	if s == nil {
		return nil
	}
	for _, a := range s.Attributes() {
		if string(a.Key) == key {
			return a.Value.AsInterface()
		}
	}
	return nil
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	m := map[string]int{}
	for _, x := range a {
		m[x]++
	}
	for _, x := range b {
		m[x]--
	}
	for _, n := range m {
		if n != 0 {
			return false
		}
	}
	return true
}

// 413/429/400 은 ERROR 가 아니고 lgtm.status 만 붙는다.
func TestRejectedRequestsAreNotErrors(t *testing.T) {
	srv, rec, _, _ := newCaptureServer(t, newFakeCompiler(t, nil).srv.URL, okExec(), &fakeUploader{})
	post(t, srv.URL, `not json`)
	post(t, srv.URL, `{"language":"go","code":"x"}`)
	_, _ = http.Post(srv.URL, "application/json", strings.NewReader(`{"language":"rust","code":"`+strings.Repeat("a", 70000)+`"}`))
	got := map[any]bool{}
	for _, s := range rec.Ended() {
		if s.Status().Code == codes.Error {
			t.Errorf("%s 가 ERROR", s.Name())
		}
		got[attrOf(s, "lgtm.status")] = true
	}
	for _, want := range []string{"invalid_request", "payload_too_large"} {
		if !got[want] {
			t.Errorf("lgtm.status=%s 없음 (%v)", want, got)
		}
	}
}

// 긴 분류 문구도 512바이트(UTF-8 경계)로 잘린다.
func TestFailSpanTruncatesTo512(t *testing.T) {
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	_, sp := tp.Tracer("t").Start(context.Background(), "x")
	telemetry.FailSpan(sp, strings.Repeat("가", 400)) // 1200바이트
	sp.End()
	s := rec.Ended()[0]
	if n := len(s.Status().Description); n > 512 || n < 510 {
		t.Errorf("description %d바이트", n)
	}
	if n := len(s.Events()[0].Attributes[0].Value.AsString()); n > 512 {
		t.Errorf("event message %d바이트", n)
	}
}

// lgtm_output_bytes: 실행이 끝난 요청만, stdout+stderr 합, 지정한 bucket, label 없음. compile_error 는 기록하지 않는다.
func TestOutputBytesHistogram(t *testing.T) {
	ex := &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusSuccess, Stdout: strings.Repeat("a", 100), Stderr: strings.Repeat("b", 28)}}
	srv, _, reader, _ := newCaptureServer(t, newFakeCompiler(t, nil).srv.URL, ex, &fakeUploader{})
	post(t, srv.URL, codeBody(`fn main() {}`))
	post(t, srv.URL, codeBody(syntaxErr)) // compile_error → 기록 없음
	var rm metricdata.ResourceMetrics
	if err := reader.Collect(context.Background(), &rm); err != nil {
		t.Fatal(err)
	}
	for _, sm := range rm.ScopeMetrics {
		for _, mm := range sm.Metrics {
			if mm.Name != telemetry.MetricOutput {
				continue
			}
			h, ok := mm.Data.(metricdata.Histogram[int64])
			if !ok || len(h.DataPoints) != 1 {
				t.Fatalf("histogram 형태: %T %d", mm.Data, len(h.DataPoints))
			}
			dp := h.DataPoints[0]
			if dp.Count != 1 || dp.Sum != 128 {
				t.Errorf("count=%d sum=%d 기대 1/128", dp.Count, dp.Sum)
			}
			if dp.Attributes.Len() != 0 {
				t.Errorf("label 있음: %v", dp.Attributes)
			}
			if fmt.Sprint(dp.Bounds) != fmt.Sprint(telemetry.OutputBuckets) || mm.Unit != "By" {
				t.Errorf("bounds=%v unit=%s", dp.Bounds, mm.Unit)
			}
			return
		}
	}
	t.Fatal("lgtm_output histogram 없음")
}
