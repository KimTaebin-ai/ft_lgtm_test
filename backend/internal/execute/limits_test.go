package execute

import (
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"

	"lgtm/backend/internal/wasmexec"
)

func TestBodyTooLarge413(t *testing.T) {
	srv, _, reader := newServerWithMetrics(t)
	big := codeBody(strings.Repeat("a", 65*1024))

	// Content-Length가 큰 경우: 본문을 읽지 않고 거부
	resp, m := post(t, srv.URL, big)
	if resp.StatusCode != http.StatusRequestEntityTooLarge || m["status"] != "payload_too_large" {
		t.Fatalf("CL: HTTP %d %v", resp.StatusCode, m)
	}

	// Content-Length 없음(chunked): MaxBytesReader가 읽는 양을 제한
	req, _ := http.NewRequest(http.MethodPost, srv.URL, io.NopCloser(strings.NewReader(big)))
	req.ContentLength = -1
	cresp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	cresp.Body.Close()
	if cresp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("chunked: HTTP %d", cresp.StatusCode)
	}

	// 64KB 안쪽은 413이 아니다
	resp, m = post(t, srv.URL, codeBody(strings.Repeat("a", 60*1024)+"\nfn main() {}"))
	if resp.StatusCode != http.StatusOK || m["status"] != "success" {
		t.Fatalf("60KB: HTTP %d %v", resp.StatusCode, m)
	}

	// 실행된 1건만 executions에 기록된다 (413은 제외)
	if n := executionsCount(t, reader); n != 1 {
		t.Errorf("lgtm_executions = %d, 기대 1", n)
	}
}

// blockExec는 release 채널이 닫힐 때까지 Run을 붙잡아 슬롯을 점유한다.
type blockExec struct {
	started chan struct{}
	release chan struct{}
}

func (b *blockExec) Run([]byte) (wasmexec.Result, error) {
	b.started <- struct{}{}
	<-b.release
	return wasmexec.Result{Status: wasmexec.StatusSuccess}, nil
}

// 처리 2 + 대기 8 = 10개까지 받고 11번째는 즉시 429. 429는 executions에 들어가지 않고 rejected만 증가한다.
func TestQueueFull429(t *testing.T) {
	ex := &blockExec{started: make(chan struct{}, 20), release: make(chan struct{})}
	srv, rec, reader := newServerWithExec(t, newFakeCompiler(t, nil).srv.URL, ex)

	codes := make(chan int, 10)
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, _ := post(t, srv.URL, codeBody(`fn main() {}`))
			codes <- resp.StatusCode
		}()
	}
	for i := 0; i < 2; i++ { // 처리 2개가 execute에 도달
		select {
		case <-ex.started:
		case <-time.After(5 * time.Second):
			t.Fatal("처리 2개가 시작되지 않음")
		}
	}
	time.Sleep(300 * time.Millisecond) // 나머지 8개가 대기열에 들어갈 시간

	start := time.Now()
	resp, m := post(t, srv.URL, codeBody(`fn main() {}`))
	if resp.StatusCode != http.StatusTooManyRequests || m["status"] != "queue_full" {
		t.Fatalf("11번째: HTTP %d %v", resp.StatusCode, m)
	}
	if d := time.Since(start); d > time.Second {
		t.Errorf("429가 즉시 반환되지 않음: %v", d)
	}

	close(ex.release)
	wg.Wait()
	close(codes)
	for c := range codes {
		if c != http.StatusOK {
			t.Errorf("대기했던 요청 HTTP %d", c)
		}
	}

	if n := executionsCount(t, reader); n != 10 {
		t.Errorf("lgtm_executions = %d, 기대 10 (429 제외)", n)
	}
	if n := counterSum(t, reader, "lgtm_queue_rejected"); n != 1 {
		t.Errorf("lgtm_queue_rejected = %d, 기대 1", n)
	}
	if n := histCount(t, reader, "lgtm_stage_duration", "queue"); n != 10 {
		t.Errorf("stage=queue count = %d, 기대 10 (대기 0도 기록)", n)
	}
	rejected := false
	for _, s := range rec.Ended() {
		for _, a := range s.Attributes() {
			if string(a.Key) == "queue.rejected" && a.Value.AsBool() {
				rejected = true
			}
		}
	}
	if !rejected {
		t.Error("429 root span에 queue.rejected 없음")
	}
}

func executionsCount(t *testing.T, r *sdkmetric.ManualReader) int64 {
	return counterSum(t, r, "lgtm_executions")
}

func counterSum(t *testing.T, r *sdkmetric.ManualReader, name string) int64 {
	t.Helper()
	m, ok := collect(t, r)[name]
	if !ok {
		return 0
	}
	var n int64
	for _, dp := range m.Data.(metricdata.Sum[int64]).DataPoints {
		n += dp.Value
	}
	return n
}

func histCount(t *testing.T, r *sdkmetric.ManualReader, name, stage string) uint64 {
	t.Helper()
	m, ok := collect(t, r)[name]
	if !ok {
		return 0
	}
	var n uint64
	for _, dp := range m.Data.(metricdata.Histogram[float64]).DataPoints {
		if v, ok := dp.Attributes.Value("stage"); ok && v.AsString() == stage {
			n += dp.Count
		}
	}
	return n
}
