package compile

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func shCmd(script string) CmdFunc {
	return func(ctx context.Context, _ string) *exec.Cmd { return exec.CommandContext(ctx, "sh", "-c", script) }
}

func newTestRunner(t *testing.T, script string, concurrency int) *Runner {
	t.Helper()
	r := NewRunner(slog.New(slog.NewTextHandler(io.Discard, nil)), t.TempDir(), concurrency)
	r.NewCmd = shCmd(script)
	return r
}

func assertWorkDirEmpty(t *testing.T, r *Runner) {
	t.Helper()
	ents, err := os.ReadDir(r.WorkDir)
	if err != nil || len(ents) != 0 {
		t.Errorf("work dir 가 비어 있지 않음: %v err=%v", ents, err)
	}
}

func TestRunSuccessRemovesTempDir(t *testing.T) {
	r := newTestRunner(t, `printf '\0asm' > out.wasm`, 2)
	wasm, _, err := r.Run(t.Context(), []byte("fn main(){}"))
	if err != nil || string(wasm) != "\x00asm" {
		t.Fatalf("wasm=%q err=%v", wasm, err)
	}
	assertWorkDirEmpty(t, r)
}

func TestRunCompileErrorKeepsStderrAndRemovesTempDir(t *testing.T) {
	r := newTestRunner(t, `echo "error: boom" >&2; exit 1`, 2)
	_, _, err := r.Run(t.Context(), []byte("x"))
	var ce *CompileError
	if !errors.As(err, &ce) || !strings.Contains(ce.Stderr, "error: boom") {
		t.Fatalf("err=%v", err)
	}
	assertWorkDirEmpty(t, r)
}

func TestSourceIsWrittenToWorkDir(t *testing.T) {
	r := newTestRunner(t, `grep -q hello main.rs && printf '\0asm' > out.wasm`, 2)
	if _, _, err := r.Run(t.Context(), []byte("// hello")); err != nil {
		t.Fatal(err)
	}
}

// 15초 timeout 의 단위 테스트 대체: 느린 명령 + 자식 프로세스를 주입하고 timeout 을 줄여 쓴다.
func TestTimeoutKillsWholeProcessGroup(t *testing.T) {
	pidFile := t.TempDir() + "/child.pid"
	r := newTestRunner(t, `sleep 60 & echo $! > `+pidFile+`; wait`, 2)
	r.Timeout = 300 * time.Millisecond

	t0 := time.Now()
	_, _, err := r.Run(t.Context(), []byte("x"))
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("err=%v (ErrTimeout 기대)", err)
	}
	if d := time.Since(t0); d > 5*time.Second {
		t.Errorf("timeout 후 반환이 너무 늦음: %v", d)
	}
	b, rerr := os.ReadFile(pidFile)
	if rerr != nil {
		t.Fatalf("자식 pid 파일 없음: %v", rerr)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	// sh 의 자식(sleep)이 그룹 kill 로 죽었는지 확인한다. 좀비 reaping 지연을 위해 잠시 재시도한다.
	dead := false
	for i := 0; i < 50 && !dead; i++ {
		if !processAlive(pid) {
			dead = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !dead {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		t.Errorf("자식 프로세스 %d 가 살아 있음 (프로세스 그룹 kill 실패)", pid)
	}
	assertWorkDirEmpty(t, r)
}

// processAlive는 좀비를 죽은 것으로 본다. 컨테이너(go test 를 PID 1 아래에서 실행)에서는 고아가 된 자식이
// reaping 되지 않아 kill(pid, 0)이 계속 성공하므로 /proc 의 상태 문자를 본다.
func processAlive(pid int) bool {
	if b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil {
		s := string(b)
		return s[strings.LastIndexByte(s, ')')+2] != 'Z'
	}
	return syscall.Kill(pid, 0) == nil
}

func TestRequestCancelStopsCompile(t *testing.T) {
	r := newTestRunner(t, `sleep 60`, 2)
	ctx, cancel := context.WithTimeout(t.Context(), 200*time.Millisecond)
	defer cancel()
	_, _, err := r.Run(ctx, []byte("x"))
	if !errors.Is(err, context.DeadlineExceeded) || errors.Is(err, ErrTimeout) {
		t.Fatalf("err=%v", err)
	}
	assertWorkDirEmpty(t, r)
}

// peakHandler 는 "compile started"/"compile finished" 로그로 동시 실행 peak 를 센다 (VM 검증과 같은 방식).
type peakHandler struct {
	mu        *sync.Mutex
	cur, peak *int
}

func (peakHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h peakHandler) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	switch r.Message {
	case "compile started":
		*h.cur++
		*h.peak = max(*h.peak, *h.cur)
	case "compile finished":
		*h.cur--
	}
	return nil
}
func (h peakHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h peakHandler) WithGroup(string) slog.Handler      { return h }

func TestSemaphoreLimitsConcurrencyAndWaits(t *testing.T) {
	var mu sync.Mutex
	cur, peak := 0, 0
	r := NewRunner(slog.New(peakHandler{&mu, &cur, &peak}), t.TempDir(), 2)
	r.NewCmd = shCmd(`sleep 0.3; printf '\0asm' > out.wasm`)

	var wg sync.WaitGroup
	errs := make(chan error, 3)
	for range 3 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, err := r.Run(t.Context(), []byte("x"))
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil { // 3번째 요청도 거부되지 않고 기다렸다가 성공해야 한다
			t.Errorf("err=%v", err)
		}
	}
	if peak != 2 {
		t.Errorf("동시 실행 peak=%d (기대 2)", peak)
	}
}

func TestSemaphoreWaitDoesNotCountTowardTimeout(t *testing.T) {
	r := newTestRunner(t, `sleep 0.4; printf '\0asm' > out.wasm`, 1)
	r.Timeout = 700 * time.Millisecond // 대기 포함이면 두 번째 요청은 실패한다
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); _, _, err := r.Run(t.Context(), []byte("x")); errs <- err }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Errorf("err=%v", err)
		}
	}
}

func TestHandlerStatusMapping(t *testing.T) {
	cases := []struct {
		name, script string
		timeout      time.Duration
		code         int
		body         string
	}{
		{"ok", `printf '\0asm' > out.wasm`, time.Second, 200, "\x00asm"},
		{"rustc error", `echo "error: boom" >&2; exit 1`, time.Second, 422, "error: boom\n"},
		{"timeout", `sleep 60`, 200 * time.Millisecond, 504, "compile timeout (200ms)\n"},
		{"missing output", `true`, time.Second, 500, "internal error\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newTestRunner(t, c.script, 2)
			r.Timeout = c.timeout
			srv := httptest.NewServer(NewHandler(r, r.Log))
			defer srv.Close()
			resp, err := http.Post(srv.URL, "text/plain", strings.NewReader("fn main(){}"))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			b, _ := io.ReadAll(resp.Body)
			if resp.StatusCode != c.code || string(b) != c.body {
				t.Errorf("got %d %q, want %d %q", resp.StatusCode, b, c.code, c.body)
			}
			assertWorkDirEmpty(t, r)
		})
	}
}

func TestHandlerRejectsEmptyBody(t *testing.T) {
	r := newTestRunner(t, `true`, 2)
	srv := httptest.NewServer(NewHandler(r, r.Log))
	defer srv.Close()
	resp, err := http.Post(srv.URL, "text/plain", strings.NewReader(""))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Errorf("status=%d", resp.StatusCode)
	}
}
