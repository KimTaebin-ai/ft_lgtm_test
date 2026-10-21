package execute

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"lgtm/backend/internal/telemetry"
)

func newServer(t *testing.T) (*httptest.Server, *tracetest.SpanRecorder) {
	t.Helper()
	srv, rec, _ := newServerWithMetrics(t)
	return srv, rec
}

func newServerWithMetrics(t *testing.T) (*httptest.Server, *tracetest.SpanRecorder, *sdkmetric.ManualReader) {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	reader := sdkmetric.NewManualReader()
	m, err := telemetry.NewMetrics(sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader)))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(NewHandler(slog.New(slog.NewTextHandler(io.Discard, nil)), tp, m))
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
	_, bad := post(t, srv.URL, codeBody(`/* __fail_compile__ */`))
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
	if ms := collect(t, reader); len(ms) != 0 {
		t.Errorf("400 요청은 metric을 기록하지 않아야 함: %v", ms)
	}
}
