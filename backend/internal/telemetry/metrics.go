package telemetry

import (
	"context"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// OTel instrument 이름에는 접미사를 붙이지 않는다. Collector의 prometheus_remote_write가
// counter에 _total, unit "s"에 _seconds를 붙여 Mimir에는 PRD 8.2 이름으로 저장된다.
//
//	lgtm_executions          → lgtm_executions_total
//	lgtm_execution_duration  → lgtm_execution_duration_seconds_{bucket,sum,count}
//	lgtm_stage_duration      → lgtm_stage_duration_seconds_{bucket,sum,count}
const (
	MetricExecutions        = "lgtm_executions"
	MetricExecutionDuration = "lgtm_execution_duration"
	MetricStageDuration     = "lgtm_stage_duration"
)

// DurationBuckets는 PRD 8.2: 5초 limit 근처를 촘촘하게. 두 histogram이 공통으로 쓴다.
var DurationBuckets = []float64{0.05, 0.1, 0.25, 0.5, 1, 2, 3, 4, 4.5, 5, 5.5, 10, 20}

// Metrics는 PRD 8.2 instrument 묶음. label에는 CID/hash 같은 high-cardinality 값을 넣지 않는다.
type Metrics struct {
	executions metric.Int64Counter
	execDur    metric.Float64Histogram
	stageDur   metric.Float64Histogram
}

func NewMetrics(mp metric.MeterProvider) (*Metrics, error) {
	m := mp.Meter(ServiceName)
	executions, err := m.Int64Counter(MetricExecutions,
		metric.WithUnit("{execution}"),
		metric.WithDescription("실행 요청 수 (status, language)"))
	if err != nil {
		return nil, err
	}
	execDur, err := m.Float64Histogram(MetricExecutionDuration,
		metric.WithUnit("s"),
		metric.WithDescription("요청 전체(root span) 소요 시간"),
		metric.WithExplicitBucketBoundaries(DurationBuckets...))
	if err != nil {
		return nil, err
	}
	stageDur, err := m.Float64Histogram(MetricStageDuration,
		metric.WithUnit("s"),
		metric.WithDescription("단계별(compile|execute|ipfs_upload) 소요 시간"),
		metric.WithExplicitBucketBoundaries(DurationBuckets...))
	if err != nil {
		return nil, err
	}
	return &Metrics{executions: executions, execDur: execDur, stageDur: stageDur}, nil
}

// RecordExecution은 counter와 duration histogram을 기록한다.
// ctx는 root span이 아직 끝나지 않은 것이어야 exemplar에 trace_id가 붙는다 (span.End() 전에 호출).
func (m *Metrics) RecordExecution(ctx context.Context, status, language string, d time.Duration) {
	attrs := metric.WithAttributes(
		attribute.String("status", status),
		attribute.String("language", language),
	)
	m.executions.Add(ctx, 1, attrs)
	m.execDur.Record(ctx, d.Seconds(), attrs)
}

// RecordStage는 stage(compile|execute|ipfs_upload) duration을 기록한다. ctx는 해당 stage span의 ctx.
func (m *Metrics) RecordStage(ctx context.Context, stage string, d time.Duration) {
	m.stageDur.Record(ctx, d.Seconds(), metric.WithAttributes(attribute.String("stage", stage)))
}
