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
	"lgtm/backend/internal/httpserver"
	"lgtm/backend/internal/ipfs"
	"lgtm/backend/internal/telemetry"
	"lgtm/backend/internal/wasmexec"
)

// defaultCompilerURL은 같은 namespace(lgtm)의 compiler Service다. COMPILER_URL로 바꿀 수 있다.
const defaultCompilerURL = "http://compiler.lgtm.svc.cluster.local/compile"

// defaultIPFSAPIURL은 Kubo API(5001) ClusterIP Service다 (Ingress에는 없다). IPFS_API_URL로 바꿀 수 있다.
const defaultIPFSAPIURL = "http://kubo-api.ipfs.svc.cluster.local:5001"

// shutdownTimeout: 큐 대기 상한(execute.maxQueueWait 45s) + 처리(loop {} ≈ 5.5s, Kubo 장애 시 ≈ 15s)까지 기다린다.
// k8s grace 75s = preStop 10s + 60s + 여유.
const shutdownTimeout = 60 * time.Second

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
	compilerURL := httpserver.Getenv("COMPILER_URL", defaultCompilerURL)
	ipfsURL := httpserver.Getenv("IPFS_API_URL", defaultIPFSAPIURL)
	runner, err := wasmexec.New()
	if err != nil {
		return fmt.Errorf("wasmexec: %w", err)
	}
	defer runner.Close()
	execute.InitMetrics(tel.Metrics)
	mux.Handle("POST /api/execute", execute.NewHandler(log, tel.TracerProvider, tel.Metrics, compilerURL, runner, ipfs.New(ipfsURL), execute.NewLimiter()))

	err = httpserver.Run(ctx, log, "backend", httpserver.Getenv("LISTEN_ADDR", ":8080"), mux, shutdownTimeout)
	// provider Shutdown으로 남은 span/log를 flush한다
	return errors.Join(err, tel.Shutdown())
}
