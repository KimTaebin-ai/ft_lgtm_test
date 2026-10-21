package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"testing"

	"go.opentelemetry.io/otel/trace"
)

func testCtx() context.Context {
	tid, _ := trace.TraceIDFromHex("4bf92f3577b34da6a3ce929d0e0e4736")
	sid, _ := trace.SpanIDFromHex("00f067aa0ba902b7")
	sc := trace.NewSpanContext(trace.SpanContextConfig{TraceID: tid, SpanID: sid, TraceFlags: trace.FlagsSampled})
	return trace.ContextWithSpanContext(context.Background(), sc)
}

func logLine(t *testing.T, buf *bytes.Buffer) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(buf.Bytes(), &m); err != nil {
		t.Fatalf("JSON 아님: %q: %v", buf.String(), err)
	}
	return m
}

func TestCtxHandlerTraceFields(t *testing.T) {
	const tid, sid = "4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"
	cases := map[string]func(*slog.Logger) *slog.Logger{
		"plain":         func(l *slog.Logger) *slog.Logger { return l },
		"With":          func(l *slog.Logger) *slog.Logger { return l.With("k", "v") },
		"WithGroup":     func(l *slog.Logger) *slog.Logger { return l.WithGroup("g") },
		"With+Group":    func(l *slog.Logger) *slog.Logger { return l.With("k", "v").WithGroup("g") },
		"Group+With":    func(l *slog.Logger) *slog.Logger { return l.WithGroup("g").With("k", "v") },
		"Group+Group":   func(l *slog.Logger) *slog.Logger { return l.WithGroup("a").WithGroup("b").With("k", "v") },
		"With+Group+Wi": func(l *slog.Logger) *slog.Logger { return l.With("x", 1).WithGroup("g").With("k", "v") },
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			var buf bytes.Buffer
			l := mk(slog.New(NewCtxJSONHandler(&buf, nil)))
			l.InfoContext(testCtx(), "hello", "a", 1)
			m := logLine(t, &buf)
			if m["trace_id"] != tid || m["span_id"] != sid {
				t.Fatalf("최상위에 trace_id/span_id 없음: %v", m)
			}
		})
	}
}

func TestCtxHandlerKeepsAttrsAndGroups(t *testing.T) {
	var buf bytes.Buffer
	l := slog.New(NewCtxJSONHandler(&buf, nil)).With("k", "v").WithGroup("g")
	l.InfoContext(testCtx(), "hello", "a", 1)
	m := logLine(t, &buf)
	g, _ := m["g"].(map[string]any)
	if m["k"] != "v" || g["a"] != float64(1) {
		t.Fatalf("With/WithGroup 결과가 보존되지 않음: %v", m)
	}
}

func TestCtxHandlerNoSpan(t *testing.T) {
	var buf bytes.Buffer
	slog.New(NewCtxJSONHandler(&buf, nil)).InfoContext(context.Background(), "x")
	m := logLine(t, &buf)
	if _, ok := m["trace_id"]; ok {
		t.Fatalf("span 없는데 trace_id 존재: %v", m)
	}
}

func TestMultiHandlerFanOut(t *testing.T) {
	var a, b bytes.Buffer
	l := slog.New(slog.NewMultiHandler(NewCtxJSONHandler(&a, nil), NewCtxJSONHandler(&b, nil))).With("k", "v")
	l.InfoContext(testCtx(), "x")
	for _, buf := range []*bytes.Buffer{&a, &b} {
		if m := logLine(t, buf); m["trace_id"] == nil || m["k"] != "v" {
			t.Fatalf("fan-out 결과 이상: %v", m)
		}
	}
}
