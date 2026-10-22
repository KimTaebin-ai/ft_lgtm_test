// Command api는 LGTM backend API 서버다.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"lgtm/backend/internal/execute"
	"lgtm/backend/internal/telemetry"
)

// defaultCompilerURL은 같은 namespace(lgtm)의 compiler Service다. COMPILER_URL로 바꿀 수 있다.
const defaultCompilerURL = "http://compiler.lgtm.svc.cluster.local/compile"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tel, err := telemetry.Setup(ctx, telemetry.ServiceName)
	if err != nil {
		return fmt.Errorf("telemetry: %w", err)
	}
	log := tel.Logger
	slog.SetDefault(log)

	mux := http.NewServeMux()
	// K8s probe 전용. 계측하지 않고 Ingress에도 노출하지 않는다.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	compilerURL := os.Getenv("COMPILER_URL")
	if compilerURL == "" {
		compilerURL = defaultCompilerURL
	}
	mux.Handle("POST /api/execute", execute.NewHandler(log, tel.TracerProvider, tel.Metrics, compilerURL))

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	log.InfoContext(ctx, "backend listening", "addr", addr)

	select {
	case err = <-errCh:
	case <-ctx.Done():
		log.InfoContext(context.Background(), "shutdown signal received")
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		err = srv.Shutdown(sctx)
	}
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	log.InfoContext(context.Background(), "backend stopped")
	// provider Shutdown으로 남은 span/log를 flush한다
	return errors.Join(err, tel.Shutdown())
}
