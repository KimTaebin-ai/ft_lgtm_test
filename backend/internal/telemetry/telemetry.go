// Package telemetry는 OTel TracerProvider/LoggerProvider와 slog fan-out logger를 구성한다.
package telemetry

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

const (
	// ServiceName은 backend의 service.name이자 metric meter 이름이다.
	ServiceName = "lgtm-backend"
	// CompilerServiceName은 compiler pod의 service.name (F-M2-01).
	CompilerServiceName = "lgtm-compiler"
	defaultEndpoint     = "otel-collector.observability:4317"

	// PeriodicReader 기본값은 60초(sdk/metric v1.47.0 periodic_reader.go defaultInterval)라 대시보드와 exemplar가 1분 늦는다.
	metricExportInterval = 5 * time.Second
)

// Telemetry는 Setup 결과. Shutdown은 종료 시 batch를 flush한다.
type Telemetry struct {
	Logger         *slog.Logger
	TracerProvider *sdktrace.TracerProvider
	MeterProvider  *sdkmetric.MeterProvider
	Metrics        *Metrics
	lp             *sdklog.LoggerProvider
}

// Setup은 OTLP gRPC exporter(Collector)로 trace/metric/log를 보내도록 구성한다.
// endpoint는 OTLP_ENDPOINT 환경변수, 없으면 otel-collector.observability:4317.
func Setup(ctx context.Context, serviceName string) (*Telemetry, error) {
	endpoint := os.Getenv("OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = defaultEndpoint
	}
	res, err := resource.New(ctx,
		resource.WithAttributes(attribute.String("service.name", serviceName)),
		resource.WithTelemetrySDK(),
	)
	if err != nil {
		return nil, err
	}

	texp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(endpoint), otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(texp), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{}) // W3C traceparent (backend→compiler 전파)

	lexp, err := otlploggrpc.New(ctx, otlploggrpc.WithEndpoint(endpoint), otlploggrpc.WithInsecure())
	if err != nil {
		return nil, errors.Join(err, tp.Shutdown(ctx))
	}
	lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewBatchProcessor(lexp)), sdklog.WithResource(res))

	// exemplar filter는 SDK 기본값(exemplar.TraceBasedFilter: sampled span ctx일 때만)을 그대로 쓴다.
	// 근거: sdk/metric v1.47.0 config.go newConfig / WithExemplarFilter. OTEL_METRICS_EXEMPLAR_FILTER 로 바꿀 수 있다.
	// temporality는 기본 cumulative (prometheus_remote_write가 delta histogram을 버린다).
	mexp, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithEndpoint(endpoint), otlpmetricgrpc.WithInsecure())
	if err != nil {
		return nil, errors.Join(err, lp.Shutdown(ctx), tp.Shutdown(ctx))
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(mexp, sdkmetric.WithInterval(metricExportInterval))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)
	metrics, err := NewMetrics(mp)
	if err != nil {
		return nil, errors.Join(err, mp.Shutdown(ctx), lp.Shutdown(ctx), tp.Shutdown(ctx))
	}

	logger := slog.New(slog.NewMultiHandler(
		otelslog.NewHandler(serviceName, otelslog.WithLoggerProvider(lp)),
		NewCtxJSONHandler(os.Stdout, nil),
	))
	return &Telemetry{Logger: logger, TracerProvider: tp, MeterProvider: mp, Metrics: metrics, lp: lp}, nil
}

// Shutdown은 metric → 로그 → trace 순으로 flush한다. ctx와 별개로 10초 한도를 둔다.
func (t *Telemetry) Shutdown() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return errors.Join(t.MeterProvider.Shutdown(ctx), t.lp.Shutdown(ctx), t.TracerProvider.Shutdown(ctx))
}
