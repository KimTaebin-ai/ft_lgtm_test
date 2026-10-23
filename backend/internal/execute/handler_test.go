package execute

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"lgtm/backend/internal/telemetry"
	"lgtm/backend/internal/wasmexec"
)

func init() {
	// 운영에서는 telemetry.Setup이 설정한다. compiler 호출의 traceparent 주입 검증에 필요하다.
	otel.SetTextMapPropagator(propagation.TraceContext{})
}

const (
	wasmMagic = "\x00asm\x01\x00\x00\x00"
	syntaxErr = "SYNTAX_ERR" // fake compiler가 이 문자열이 있으면 rustc 실패(422)를 흉내 낸다
)

// fakeCompiler는 소스에 syntaxErr가 있으면 422, 아니면 최소 wasm 헤더를 반환한다. 받은 traceparent를 기록한다.
type fakeCompiler struct {
	srv         *httptest.Server
	traceparent chan string
}

func newFakeCompiler(t *testing.T, h http.HandlerFunc) *fakeCompiler {
	t.Helper()
	fc := &fakeCompiler{traceparent: make(chan string, 8)}
	fc.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case fc.traceparent <- r.Header.Get("traceparent"):
		default:
		}
		if h != nil {
			h(w, r)
			return
		}
		b, _ := io.ReadAll(r.Body)
		if strings.Contains(string(b), syntaxErr) {
			http.Error(w, "error: expected expression, found `;`\n --> main.rs:1:1\n", http.StatusUnprocessableEntity)
			return
		}
		w.Header().Set("Content-Type", "application/wasm")
		_, _ = w.Write([]byte(wasmMagic))
	}))
	t.Cleanup(fc.srv.Close)
	return fc
}

func newServer(t *testing.T) (*httptest.Server, *tracetest.SpanRecorder) {
	t.Helper()
	srv, rec, _ := newServerWithMetrics(t)
	return srv, rec
}

func newServerWithMetrics(t *testing.T) (*httptest.Server, *tracetest.SpanRecorder, *sdkmetric.ManualReader) {
	t.Helper()
	return newServerFor(t, newFakeCompiler(t, nil).srv.URL)
}

// fakeExec는 wasmexec 대신 고정된 결과를 돌려준다 (실제 실행은 wasmexec 패키지 테스트와 m2-03.sh 가 검증).
type fakeExec struct {
	res wasmexec.Result
	err error
}

func (f *fakeExec) Run([]byte) (wasmexec.Result, error) { return f.res, f.err }

func okExec() *fakeExec {
	return &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusSuccess, Stdout: "stub output\n"}}
}

func newServerFor(t *testing.T, compilerURL string) (*httptest.Server, *tracetest.SpanRecorder, *sdkmetric.ManualReader) {
	return newServerWithExec(t, compilerURL, okExec())
}

func newServerWithExec(t *testing.T, compilerURL string, ex Executor) (*httptest.Server, *tracetest.SpanRecorder, *sdkmetric.ManualReader) {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	reader := sdkmetric.NewManualReader()
	m, err := telemetry.NewMetrics(sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader)))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(NewHandler(slog.New(slog.NewTextHandler(io.Discard, nil)), tp, m, compilerURL, ex, NewLimiter()))
	t.Cleanup(srv.Close)
	return srv, rec, reader
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
	resp, m := post(t, srv.URL, codeBody(`fn main() { let x = ; /* `+syntaxErr+` */ }`))
	if resp.StatusCode != 200 || m["status"] != "compile_error" || m["message"] != "error: expected expression, found `;`" {
		t.Fatalf("응답 이상: %d %v", resp.StatusCode, m)
	}
	if s, _ := m["stderr"].(string); !strings.Contains(s, "main.rs:1:1") {
		t.Errorf("stderr 에 rustc 메시지 전체가 없음: %q", s)
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

func TestTraceparentParentIsCompileSpan(t *testing.T) {
	fc := newFakeCompiler(t, nil)
	srv, rec, _ := newServerFor(t, fc.srv.URL)
	_, m := post(t, srv.URL, codeBody(`fn main() {}`))
	tp := <-fc.traceparent
	var compileID string
	for _, s := range rec.Ended() {
		if s.Name() == "compile" {
			compileID = s.SpanContext().SpanID().String()
		}
		// transport 가 client span 을 따로 만들면 parent 가 어긋난다: 이름이 compile 인 span 은 하나뿐이어야 한다.
	}
	want := "00-" + m["trace_id"].(string) + "-" + compileID + "-01"
	if tp != want {
		t.Errorf("traceparent=%q want %q", tp, want)
	}
	if n := len(rec.Ended()); n != 4 {
		t.Errorf("backend span %d개 (HTTP client span 이 추가됐나?)", n)
	}
}

func TestCompileTimeoutIsCompileError(t *testing.T) {
	fc := newFakeCompiler(t, func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "compile timeout (15s)", http.StatusGatewayTimeout)
	})
	srv, _, _ := newServerFor(t, fc.srv.URL)
	resp, m := post(t, srv.URL, codeBody(`fn main() {}`))
	if resp.StatusCode != 200 || m["status"] != "compile_error" || m["message"] != "compile timeout (15s)" {
		t.Fatalf("응답 이상: %d %v", resp.StatusCode, m)
	}
}

// internal_error: 플랫폼 원인(연결 실패, compiler 5xx, wasm 상한 초과). HTTP 200, 스키마 동일, root span ERROR.
func TestInternalError(t *testing.T) {
	down := newFakeCompiler(t, nil)
	downURL := down.srv.URL
	down.srv.Close() // compiler 다운

	cases := map[string]string{
		"compiler 다운": downURL,
		"compiler 500": newFakeCompiler(t, func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "boom", http.StatusInternalServerError)
		}).srv.URL,
		"wasm 8MiB 초과": newFakeCompiler(t, func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write(make([]byte, maxWasmBytes+1))
		}).srv.URL,
	}
	for name, url := range cases {
		t.Run(name, func(t *testing.T) {
			srv, rec, reader := newServerFor(t, url)
			resp, m := post(t, srv.URL, codeBody(`fn main() {}`))
			if resp.StatusCode != 200 || m["status"] != "internal_error" {
				t.Fatalf("응답 이상: %d %v", resp.StatusCode, m)
			}
			if msg, _ := m["message"].(string); msg == "" {
				t.Error("message 요약 없음")
			}
			if m["stderr"] != "" || m["stdout"] != "" {
				t.Errorf("stderr/stdout 은 비어 있어야 함: %v", m)
			}
			names := map[string]sdktrace.ReadOnlySpan{}
			for _, s := range rec.Ended() {
				names[s.Name()] = s
			}
			if names["execute"] != nil || names["ipfs.upload"] == nil {
				t.Errorf("span 구성 이상 (execute 생략, ipfs.upload 수행 기대): %v", names)
			}
			for _, n := range []string{"compile", "POST /api/execute"} {
				if names[n].Status().Code.String() != "Error" {
					t.Errorf("%s status=%v (Error 기대)", n, names[n].Status().Code)
				}
			}
			sum := collect(t, reader)[telemetry.MetricExecutions].Data.(metricdata.Sum[int64])
			st, _ := sum.DataPoints[0].Attributes.Value("status")
			if st.AsString() != "internal_error" {
				t.Errorf("metric status=%s", st.AsString())
			}
		})
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

func collect(t *testing.T, r *sdkmetric.ManualReader) map[string]metricdata.Metrics {
	t.Helper()
	var rm metricdata.ResourceMetrics
	if err := r.Collect(t.Context(), &rm); err != nil {
		t.Fatal(err)
	}
	out := map[string]metricdata.Metrics{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			out[m.Name] = m
		}
	}
	return out
}

func TestMetricsNamesLabelsBucketsExemplar(t *testing.T) {
	srv, _, reader := newServerWithMetrics(t)
	_, ok := post(t, srv.URL, codeBody(`fn main() {}`))
	_, bad := post(t, srv.URL, codeBody(`/* `+syntaxErr+` */`))
	ms := collect(t, reader)

	// OTel 이름 (접미사 없음) / unit
	for name, unit := range map[string]string{
		telemetry.MetricExecutions: "{execution}", telemetry.MetricExecutionDuration: "s", telemetry.MetricStageDuration: "s",
	} {
		m, found := ms[name]
		if !found {
			t.Fatalf("metric %s 없음 (있는 것: %v)", name, ms)
		}
		if m.Unit != unit {
			t.Errorf("%s unit=%q want %q", name, m.Unit, unit)
		}
	}

	sum := ms[telemetry.MetricExecutions].Data.(metricdata.Sum[int64])
	got := map[string]int64{}
	for _, dp := range sum.DataPoints {
		st, _ := dp.Attributes.Value("status")
		lang, _ := dp.Attributes.Value("language")
		if dp.Attributes.Len() != 2 || lang.AsString() != "rust" {
			t.Errorf("executions label 세트 이상: %v", dp.Attributes)
		}
		got[st.AsString()] = dp.Value
	}
	if got["success"] != 1 || got["compile_error"] != 1 {
		t.Errorf("executions=%v", got)
	}

	// execution duration: bucket, label, exemplar trace_id == 응답 trace_id
	h := ms[telemetry.MetricExecutionDuration].Data.(metricdata.Histogram[float64])
	wantTraces := map[string]bool{ok["trace_id"].(string): false, bad["trace_id"].(string): false}
	for _, dp := range h.DataPoints {
		if dp.Attributes.Len() != 2 {
			t.Errorf("execution_duration label 세트 이상: %v", dp.Attributes)
		}
		if len(dp.Bounds) != len(telemetry.DurationBuckets) {
			t.Fatalf("bounds=%v", dp.Bounds)
		}
		for i, b := range telemetry.DurationBuckets {
			if dp.Bounds[i] != b {
				t.Errorf("bound[%d]=%v want %v", i, dp.Bounds[i], b)
			}
		}
		for _, ex := range dp.Exemplars {
			id := fmt.Sprintf("%x", ex.TraceID)
			if _, known := wantTraces[id]; known {
				wantTraces[id] = true
			}
		}
	}
	for id, seen := range wantTraces {
		if !seen {
			t.Errorf("execution_duration exemplar에 trace_id %s 없음", id)
		}
	}

	// stage duration: stage 3종, label 1개, exemplar는 해당 stage span ctx
	sh := ms[telemetry.MetricStageDuration].Data.(metricdata.Histogram[float64])
	stages := map[string]bool{}
	for _, dp := range sh.DataPoints {
		if dp.Attributes.Len() != 1 {
			t.Errorf("stage_duration label 세트 이상: %v", dp.Attributes)
		}
		st, _ := dp.Attributes.Value("stage")
		stages[st.AsString()] = true
		if len(dp.Exemplars) == 0 {
			t.Errorf("stage %s exemplar 없음", st.AsString())
		}
	}
	for _, s := range []string{"compile", "execute", "ipfs_upload"} {
		if !stages[s] {
			t.Errorf("stage %s 없음 (%v)", s, stages)
		}
	}
}

func TestInvalidRequestRecordsNoMetric(t *testing.T) {
	srv, _, reader := newServerWithMetrics(t)
	post(t, srv.URL, `{"language":"go","code":"x"}`)
	// queue gauge는 요청과 무관하게 항상 export된다. 요청이 만드는 metric만 없어야 한다.
	for name := range collect(t, reader) {
		if name != telemetry.MetricQueueActive && name != telemetry.MetricQueueWaiting {
			t.Errorf("400 요청은 metric을 기록하지 않아야 함: %s", name)
		}
	}
}

// execute 단계 status 매핑, 응답 필드, TR-04 attribute, 실패 시 execute/root span ERROR.
func TestExecuteStatusMappingAndSpanAttributes(t *testing.T) {
	cases := []struct {
		name    string
		ex      *fakeExec
		status  string
		message string
		isErr   bool
		attrs   map[string]any
	}{
		{"success", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusSuccess, Stdout: "o", Stderr: "e", Truncated: true}},
			"success", "", false, map[string]any{"exec.exit_code": int64(0), "exec.timed_out": false, "exec.output_truncated": true, "exec.memory_limited": false}},
		{"runtime_error", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusRuntimeError, Message: "exit status 3", ExitCode: 3}},
			"runtime_error", "exit status 3", true, map[string]any{"exec.exit_code": int64(3), "exec.timed_out": false, "exec.output_truncated": false, "exec.memory_limited": false}},
		{"timeout", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusTimeout, Message: "time limit exceeded (5s)", ExitCode: -1}},
			"timeout", "time limit exceeded (5s)", true, map[string]any{"exec.exit_code": int64(-1), "exec.timed_out": true, "exec.output_truncated": false, "exec.memory_limited": false}},
		{"memory_limit", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusMemoryLimit, Message: "memory limit exceeded", ExitCode: -1}},
			"memory_limit", "memory limit exceeded", true, map[string]any{"exec.exit_code": int64(-1), "exec.timed_out": false, "exec.output_truncated": false, "exec.memory_limited": true}},
		{"internal", &fakeExec{err: errors.New("engine 오류")},
			"internal_error", "internal error: engine 오류", true, map[string]any{"exec.exit_code": int64(-1), "exec.timed_out": false, "exec.output_truncated": false, "exec.memory_limited": false}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv, rec, _ := newServerWithExec(t, newFakeCompiler(t, nil).srv.URL, c.ex)
			_, m := post(t, srv.URL, codeBody(`fn main() {}`))
			if m["status"] != c.status {
				t.Fatalf("status=%v 기대 %s (%v)", m["status"], c.status, m)
			}
			if got, _ := m["message"].(string); got != c.message {
				t.Errorf("message=%q 기대 %q", got, c.message)
			}
			if c.ex.res.Stdout != "" && (m["stdout"] != c.ex.res.Stdout || m["stderr"] != c.ex.res.Stderr || m["truncated"] != c.ex.res.Truncated) {
				t.Errorf("stdout/stderr/truncated 가 응답에 반영되지 않음: %v", m)
			}
			var exec, root sdktrace.ReadOnlySpan
			for _, s := range rec.Ended() {
				switch {
				case s.Name() == "execute":
					exec = s
				case !s.Parent().IsValid():
					root = s
				}
			}
			if exec == nil || root == nil {
				t.Fatal("execute/root span 없음")
			}
			got := map[string]any{}
			for _, a := range exec.Attributes() {
				got[string(a.Key)] = a.Value.AsInterface()
			}
			for k, v := range c.attrs {
				if got[k] != v {
					t.Errorf("%s=%v (%T) 기대 %v", k, got[k], got[k], v)
				}
			}
			if (exec.Status().Code == codes.Error) != c.isErr || (root.Status().Code == codes.Error) != c.isErr {
				t.Errorf("ERROR 표시: execute=%v root=%v 기대 %v", exec.Status().Code, root.Status().Code, c.isErr)
			}
		})
	}
}
