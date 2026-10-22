// Command compiler는 Rust 소스를 wasm32-wasip1로 컴파일하는 서비스다 (F-M2-01).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/propagation"

	"lgtm/backend/internal/compile"
	"lgtm/backend/internal/telemetry"
)

// SpanName은 PRD 8.3 트리의 compile → rustc. backend compile span의 자식 server span이다.
const SpanName = "rustc"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tel, err := telemetry.Setup(ctx, telemetry.CompilerServiceName)
	if err != nil {
		return fmt.Errorf("telemetry: %w", err)
	}
	log := tel.Logger
	slog.SetDefault(log)

	workDir := os.Getenv("WORK_DIR")
	if workDir == "" {
		workDir = "/work"
	}
	cleanWorkDir(log, workDir)

	runner := compile.NewRunner(log, workDir, compile.DefaultConcurrency)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.Handle("POST /compile", otelhttp.NewHandler(compile.NewHandler(runner, log), SpanName,
		otelhttp.WithTracerProvider(tel.TracerProvider),
		otelhttp.WithPropagators(propagation.TraceContext{}),
		otelhttp.WithSpanNameFormatter(func(string, *http.Request) string { return SpanName }),
	))

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	log.InfoContext(ctx, "compiler listening", "addr", addr, "work_dir", workDir)

	select {
	case err = <-errCh:
	case <-ctx.Done():
		log.InfoContext(context.Background(), "shutdown signal received")
		sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		err = srv.Shutdown(sctx)
	}
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	log.InfoContext(context.Background(), "compiler stopped")
	return errors.Join(err, tel.Shutdown())
}

// cleanWorkDir은 이전 프로세스가 남긴 임시 디렉토리를 지운다 (컨테이너만 재시작되면 emptyDir은 남는다).
func cleanWorkDir(log *slog.Logger, dir string) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range ents {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			log.Warn("work dir 잔여물 삭제 실패", "name", e.Name(), "error", err.Error())
		}
	}
}
