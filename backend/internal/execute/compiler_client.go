package execute

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"

	"lgtm/backend/internal/compile"
)

const (
	// compilerTimeout은 compiler의 15초 timeout(SEC-07) + 네트워크/응답 읽기 여유 5초.
	compilerTimeout = 20 * time.Second
	// maxWasmBytes는 compiler 응답 상한이다. 이후 단계(Wasmtime 적재, IPFS 업로드)와 backend 메모리 limit(128Mi)를
	// 보호하려는 값이다. opt-level=1 wasip1 hello world는 수백 KB~2MB 수준이라 8MiB면 여유가 크다 (실측은 HANDOFF).
	maxWasmBytes = 8 << 20
	// maxStderrBytes는 compiler가 이미 64KiB로 자른 stderr를 한 번 더 방어적으로 자르는 상한이다.
	maxStderrBytes = 64 << 10
)

// classRe는 compiler가 보낸 분류 문구의 형태다 ("rustc failed [E0425]", "source denied [deny-rename]"). 이 밖의 값은 버린다.
var classRe = regexp.MustCompile(`^(rustc failed|source denied)( \[[A-Za-z0-9-]{1,40}\])?$`)

func classFromHeader(h http.Header) string {
	if c := h.Get(compile.ClassHeader); classRe.MatchString(c) {
		return c
	}
	return "rustc failed"
}

type compilerClient struct {
	url  string
	http *http.Client
}

// newCompilerClient의 http.Client는 일부러 otelhttp.NewTransport를 쓰지 않는다. transport가 HTTP client span을
// 하나 더 만들어 rustc span의 parent가 compile이 아니게 되기 때문이다 (PRD 8.3: compile → rustc).
// traceparent는 compile span ctx에서 직접 주입한다.
func newCompilerClient(url string) *compilerClient {
	return &compilerClient{url: url, http: &http.Client{Timeout: compilerTimeout}}
}

// compile은 ctx의 span(compile span)을 parent로 하는 traceparent를 붙여 compiler를 호출한다.
func (c *compilerClient) compile(ctx context.Context, code string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, strings.NewReader(code))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "text/plain")
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("compiler 호출 실패: %w", err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusOK:
		if resp.ContentLength > maxWasmBytes {
			return nil, fmt.Errorf("wasm 응답이 상한 %d바이트를 넘음 (Content-Length %d)", maxWasmBytes, resp.ContentLength)
		}
		wasm, err := io.ReadAll(io.LimitReader(resp.Body, maxWasmBytes+1))
		if err != nil {
			return nil, fmt.Errorf("compiler 응답 읽기 실패: %w", err)
		}
		if len(wasm) > maxWasmBytes {
			return nil, fmt.Errorf("wasm 응답이 상한 %d바이트를 넘음", maxWasmBytes)
		}
		return wasm, nil
	case resp.StatusCode == http.StatusUnprocessableEntity:
		stderr := readText(resp.Body)
		return nil, &userError{Message: firstErrorLine(stderr), Stderr: stderr, Class: classFromHeader(resp.Header)}
	case resp.StatusCode == http.StatusGatewayTimeout:
		msg := strings.TrimSpace(readText(resp.Body))
		if msg == "" {
			msg = "compile timeout"
		}
		return nil, &userError{Message: msg, Stderr: msg + "\n", Class: "compile timeout"}
	default:
		return nil, fmt.Errorf("compiler 응답 HTTP %d", resp.StatusCode)
	}
}

func readText(r io.Reader) string {
	b, _ := io.ReadAll(io.LimitReader(r, maxStderrBytes))
	return string(b)
}

// firstErrorLine은 rustc stderr에서 첫 "error" 줄을 요약 message로 쓴다. 없으면 첫 비어 있지 않은 줄.
func firstErrorLine(stderr string) string {
	first := ""
	for _, l := range bytes.Split([]byte(stderr), []byte("\n")) {
		line := strings.TrimSpace(string(l))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "error") {
			return line
		}
		if first == "" {
			first = line
		}
	}
	if first == "" {
		return "compile failed"
	}
	return first
}
