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
//	lgtm_queue_rejected      → lgtm_queue_rejected_total
//	lgtm_queue_active        → lgtm_queue_active (gauge, 처리 중)
//	lgtm_queue_waiting       → lgtm_queue_waiting (gauge, 대기 중)
const (
	MetricExecutions        = "lgtm_executions"
	MetricExecutionDuration = "lgtm_execution_duration"
	MetricStageDuration     = "lgtm_stage_duration"
	MetricQueueRejected     = "lgtm_queue_rejected"
	MetricQueueActive       = "lgtm_queue_active"
	MetricQueueWaiting      = "lgtm_queue_waiting"
)

// DurationBuckets는 PRD 8.2: 5초 limit 근처를 촘촘하게. 두 histogram이 공통으로 쓴다.
var DurationBuckets = []float64{0.05, 0.1, 0.25, 0.5, 1, 2, 3, 4, 4.5, 5, 5.5, 10, 20}

// Metrics는 PRD 8.2 instrument 묶음. label에는 CID/hash 같은 high-cardinality 값을 넣지 않는다.
type Metrics struct {
	executions metric.Int64Counter
	execDur    metric.Float64Histogram
	stageDur   metric.Float64Histogram
	rejected   metric.Int64Counter
	meter      metric.Meter
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
		metric.WithDescription("단계별(queue|compile|execute|ipfs_upload) 소요 시간"),
		metric.WithExplicitBucketBoundaries(DurationBuckets...))
	if err != nil {
		return nil, err
	}
	rejected, err := m.Int64Counter(MetricQueueRejected,
		metric.WithUnit("{request}"),
		metric.WithDescription("대기열이 가득 차거나 대기 상한 시간을 넘겨 429로 거절된 요청 수"))
	if err != nil {
		return nil, err
	}
	return &Metrics{executions: executions, execDur: execDur, stageDur: stageDur, rejected: rejected, meter: m}, nil
}

// InitSeries는 counter series를 0으로 만들어 둔다. 새 process의 첫 export부터 모든 status series가 0에서 시작하므로
// 재시작 뒤에도 이전 process의 값이 남아 보이지 않고, rate/increase 계산도 첫 증가분을 놓치지 않는다.
func (m *Metrics) InitSeries(language string, statuses []string) {
	ctx := context.Background()
	for _, st := range statuses {
		m.executions.Add(ctx, 0, metric.WithAttributes(attribute.String("status", st), attribute.String("language", language)))
	}
	m.rejected.Add(ctx, 0)
}

// RecordQueueRejected는 429 거절 1건을 센다. 실행이 시작되지 않은 요청이라 lgtm_executions에는 넣지 않는다.
func (m *Metrics) RecordQueueRejected(ctx context.Context) { m.rejected.Add(ctx, 1) }

// RegisterQueueGauges는 처리 중/대기 중 개수 gauge를 등록한다. export 때마다 콜백이 현재 값을 읽는다. label 없음.
func (m *Metrics) RegisterQueueGauges(active, waiting func() int) error {
	a, err := m.meter.Int64ObservableGauge(MetricQueueActive,
		metric.WithUnit("{request}"), metric.WithDescription("현재 처리 중인 요청 수"))
	if err != nil {
		return err
	}
	w, err := m.meter.Int64ObservableGauge(MetricQueueWaiting,
		metric.WithUnit("{request}"), metric.WithDescription("현재 대기열에서 기다리는 요청 수"))
	if err != nil {
		return err
	}
	_, err = m.meter.RegisterCallback(func(_ context.Context, o metric.Observer) error {
		o.ObserveInt64(a, int64(active()))
		o.ObserveInt64(w, int64(waiting()))
		return nil
	}, a, w)
	return err
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

// RecordStage는 stage(queue|compile|execute|ipfs_upload) duration을 기록한다. ctx는 해당 stage span의 ctx.
func (m *Metrics) RecordStage(ctx context.Context, stage string, d time.Duration) {
	m.stageDur.Record(ctx, d.Seconds(), metric.WithAttributes(attribute.String("stage", stage)))
}
