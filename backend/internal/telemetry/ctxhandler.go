package telemetry

import (
	"context"
	"io"
	"log/slog"

	"go.opentelemetry.io/otel/trace"
)

// op는 ctxHandler에 쌓인 WithAttrs/WithGroup 호출 하나.
type op struct {
	group string
	attrs []slog.Attr
}

// ctxHandler는 JSON handler를 감싸 ctx의 span에서 trace_id, span_id를 최상위 필드로 넣는다.
// slog.JSONHandler는 ctx에서 값을 꺼내지 않으므로 직접 넣어야 한다.
// WithAttrs/WithGroup도 래퍼를 유지해야 logger.With(...) 이후에도 trace_id가 빠지지 않는다.
// 그룹이 열려 있으면 record attr은 그룹 안으로 들어가므로, 그 경우에만 trace attr을
// root에 먼저 붙인 handler를 만들어 지금까지의 op를 다시 적용한다.
type ctxHandler struct {
	root    slog.Handler
	cur     slog.Handler
	ops     []op
	grouped bool
}

// NewCtxJSONHandler는 trace_id/span_id를 포함하는 JSON handler를 만든다.
func NewCtxJSONHandler(w io.Writer, opts *slog.HandlerOptions) slog.Handler {
	h := slog.NewJSONHandler(w, opts)
	return &ctxHandler{root: h, cur: h}
}

func (h *ctxHandler) Enabled(ctx context.Context, l slog.Level) bool {
	return h.cur.Enabled(ctx, l)
}

func (h *ctxHandler) Handle(ctx context.Context, r slog.Record) error {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return h.cur.Handle(ctx, r)
	}
	tid := slog.String("trace_id", sc.TraceID().String())
	sid := slog.String("span_id", sc.SpanID().String())
	if !h.grouped {
		r.AddAttrs(tid, sid)
		return h.cur.Handle(ctx, r)
	}
	nh := h.root.WithAttrs([]slog.Attr{tid, sid})
	for _, o := range h.ops {
		if o.group != "" {
			nh = nh.WithGroup(o.group)
		} else {
			nh = nh.WithAttrs(o.attrs)
		}
	}
	return nh.Handle(ctx, r)
}

func (h *ctxHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	if len(attrs) == 0 {
		return h
	}
	return &ctxHandler{root: h.root, cur: h.cur.WithAttrs(attrs), ops: appendOp(h.ops, op{attrs: attrs}), grouped: h.grouped}
}

func (h *ctxHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	return &ctxHandler{root: h.root, cur: h.cur.WithGroup(name), ops: appendOp(h.ops, op{group: name}), grouped: true}
}

func appendOp(ops []op, o op) []op {
	out := make([]op, len(ops)+1)
	copy(out, ops)
	out[len(ops)] = o
	return out
}
