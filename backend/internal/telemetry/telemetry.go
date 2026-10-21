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
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

const (
	ServiceName     = "lgtm-backend"
	defaultEndpoint = "otel-collector.observability:4317"
)

// Telemetry는 Setup 결과. Shutdown은 종료 시 batch를 flush한다.
type Telemetry struct {
	Logger         *slog.Logger
	TracerProvider *sdktrace.TracerProvider
	lp             *sdklog.LoggerProvider
}

// Setup은 OTLP gRPC exporter(Collector)로 trace/log를 보내도록 구성한다.
// endpoint는 OTLP_ENDPOINT 환경변수, 없으면 otel-collector.observability:4317.
func Setup(ctx context.Context) (*Telemetry, error) {
	endpoint := os.Getenv("OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = defaultEndpoint
	}
	res, err := resource.New(ctx,
		resource.WithAttributes(attribute.String("service.name", ServiceName)),
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
	otel.SetTextMapPropagator(propagation.TraceContext{}) // W3C traceparent (F-M2-01 대비)

	lexp, err := otlploggrpc.New(ctx, otlploggrpc.WithEndpoint(endpoint), otlploggrpc.WithInsecure())
	if err != nil {
		return nil, errors.Join(err, tp.Shutdown(ctx))
	}
	lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewBatchProcessor(lexp)), sdklog.WithResource(res))

	logger := slog.New(slog.NewMultiHandler(
		otelslog.NewHandler(ServiceName, otelslog.WithLoggerProvider(lp)),
		NewCtxJSONHandler(os.Stdout, nil),
	))
	return &Telemetry{Logger: logger, TracerProvider: tp, lp: lp}, nil
}

// Shutdown은 로그 → trace 순으로 flush한다. ctx와 별개로 10초 한도를 둔다.
func (t *Telemetry) Shutdown() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return errors.Join(t.lp.Shutdown(ctx), t.TracerProvider.Shutdown(ctx))
}
