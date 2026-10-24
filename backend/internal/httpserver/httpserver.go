// Package httpserver는 cmd/api와 cmd/compiler가 같이 쓰는 env 기본값 읽기와 서버 시작/shutdown이다.
// compiler 바이너리는 CGO_ENABLED=0 빌드라 표준 라이브러리만 쓴다.
package httpserver

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"
)

// Getenv는 환경변수 key 값을 돌려준다. 비어 있으면 def다.
func Getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Run은 addr에서 handler를 서빙하고, ctx가 끝나면 shutdownTimeout 안에서 Shutdown한다.
// "<name> listening"(addr + listenAttrs), "shutdown signal received", "<name> stopped" 로그를 남긴다.
// http.ErrServerClosed는 nil로 바꿔 돌려준다. telemetry flush는 호출자가 Run 반환 뒤에 한다.
func Run(ctx context.Context, log *slog.Logger, name, addr string, handler http.Handler, shutdownTimeout time.Duration, listenAttrs ...any) error {
	srv := &http.Server{Addr: addr, Handler: handler, ReadHeaderTimeout: 5 * time.Second}

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	log.InfoContext(ctx, name+" listening", append([]any{"addr", addr}, listenAttrs...)...)

	var err error
	select {
	case err = <-errCh:
	case <-ctx.Done():
		log.InfoContext(context.Background(), "shutdown signal received")
		sctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		err = srv.Shutdown(sctx)
	}
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	log.InfoContext(context.Background(), name+" stopped")
	return err
}
