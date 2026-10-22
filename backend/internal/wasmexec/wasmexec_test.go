package wasmexec

import (
	"strings"
	"sync"
	"testing"
	"time"

	wasmtime "github.com/bytecodealliance/wasmtime-go/v50"
)

// wat은 공통 prelude(fd_write, proc_exit, 메모리, 문자열 데이터)가 있는 WAT 모듈을 wasm으로 만든다.
// 데이터: 8 "hello\n", 16 "err\n", 32 alloc 실패 메시지(38바이트), 1024.. 영(零) 1KB 채움.
// $w(fd, ptr, len) 은 iovec 하나로 fd_write 를 호출하고 errno 를 반환한다.
func wat(t *testing.T, memory, start string) []byte {
	t.Helper()
	src := `(module
 (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
 (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 (import "wasi_snapshot_preview1" "args_sizes_get" (func $args (param i32 i32) (result i32)))
 (import "wasi_snapshot_preview1" "environ_sizes_get" (func $envs (param i32 i32) (result i32)))
 ` + memory + `
 (data (i32.const 8) "hello\n")
 (data (i32.const 16) "err\n")
 (data (i32.const 32) "memory allocation of 100 bytes failed\n")
 (func $w (param $fd i32) (param $ptr i32) (param $len i32) (result i32)
   (i32.store (i32.const 0) (local.get $ptr))
   (i32.store (i32.const 4) (local.get $len))
   (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 100)))
 (func (export "_start") (local $i i32)
 ` + start + `))`
	b, err := wasmtime.Wat2Wasm(src)
	if err != nil {
		t.Fatalf("wat: %v", err)
	}
	return b
}

const mem1 = `(memory (export "memory") 1)`

func newRunner(t *testing.T) *Runner {
	t.Helper()
	r, err := New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	return r
}

func run(t *testing.T, r *Runner, wasm []byte) Result {
	t.Helper()
	res, err := r.Run(wasm)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return res
}

func TestHelloStdoutStderrSeparated(t *testing.T) {
	r := newRunner(t)
	res := run(t, r, wat(t, mem1, `(drop (call $w (i32.const 1) (i32.const 8) (i32.const 6)))
	  (drop (call $w (i32.const 2) (i32.const 16) (i32.const 4)))`))
	if res.Status != StatusSuccess || res.Stdout != "hello\n" || res.Stderr != "err\n" || res.Truncated || res.ExitCode != 0 {
		t.Fatalf("res=%+v", res)
	}
}

func TestOutputLimitSharedAndExactly10240(t *testing.T) {
	r := newRunner(t)
	// 1KB씩 stdout 1024번(1MiB) + stderr 1번. 합계 10240에서 잘리고 nwritten은 요청 전체라 프로그램은 끝까지 간다.
	res := run(t, r, wat(t, mem1, `(loop $l
	   (drop (call $w (i32.const 1) (i32.const 1024) (i32.const 1024)))
	   (local.set $i (i32.add (local.get $i) (i32.const 1)))
	   (br_if $l (i32.lt_u (local.get $i) (i32.const 1024))))
	  (drop (call $w (i32.const 2) (i32.const 16) (i32.const 4)))`))
	if res.Status != StatusSuccess || !res.Truncated || len(res.Stdout)+len(res.Stderr) != OutputLimit || res.Stderr != "" {
		t.Fatalf("status=%s truncated=%v stdout=%d stderr=%d", res.Status, res.Truncated, len(res.Stdout), len(res.Stderr))
	}
}

func TestExitCodes(t *testing.T) {
	r := newRunner(t)
	for _, c := range []struct {
		code   string
		status string
		exit   int
	}{{"0", StatusSuccess, 0}, {"3", StatusRuntimeError, 3}} {
		res := run(t, r, wat(t, mem1, `(call $exit (i32.const `+c.code+`))`))
		if res.Status != c.status || res.ExitCode != c.exit {
			t.Errorf("exit(%s): %+v", c.code, res)
		}
	}
}

func TestTrapIsRuntimeError(t *testing.T) {
	r := newRunner(t)
	res := run(t, r, wat(t, mem1, `(drop (call $w (i32.const 1) (i32.const 8) (i32.const 6))) unreachable`))
	if res.Status != StatusRuntimeError || res.Stdout != "hello\n" || res.ExitCode != -1 {
		t.Fatalf("res=%+v", res)
	}
}

func TestCapabilityZero(t *testing.T) {
	r := newRunner(t)
	// 환경변수 0개, argv 1개, fd 3(preopen이었을 자리)에 쓰기는 EBADF(8). 값을 exit code로 내보낸다.
	res := run(t, r, wat(t, mem1, `(drop (call $envs (i32.const 200) (i32.const 204)))
	  (drop (call $args (i32.const 208) (i32.const 212)))
	  (call $exit (i32.add (i32.add (i32.load (i32.const 200)) (i32.mul (i32.load (i32.const 208)) (i32.const 2)))
	     (i32.mul (i32.eq (call $w (i32.const 3) (i32.const 8) (i32.const 6)) (i32.const 8)) (i32.const 4))))`))
	// env 0 + argc 1*2 + (EBADF)*4 = 6 (proc_exit 코드는 126 미만이어야 한다)
	if res.ExitCode != 6 {
		t.Fatalf("exit=%d (기대 6 = env0 + argc1*2 + EBADF*4) res=%+v", res.ExitCode, res)
	}
}

func TestMemoryLimitViaAllocFailureMessage(t *testing.T) {
	r := newRunner(t)
	// 1페이지 + grow 200페이지(12.5MiB) → -1, Rust처럼 alloc 메시지를 쓰고 unreachable
	res := run(t, r, wat(t, mem1, `(if (i32.eq (memory.grow (i32.const 200)) (i32.const -1))
	   (then (drop (call $w (i32.const 2) (i32.const 32) (i32.const 38))) unreachable))`))
	if res.Status != StatusMemoryLimit {
		t.Fatalf("res=%+v", res)
	}
}

func TestGrowWithinLimitSucceeds(t *testing.T) {
	r := newRunner(t)
	res := run(t, r, wat(t, mem1, `(if (i32.eq (memory.grow (i32.const 100)) (i32.const -1)) (then unreachable))`)) // 6.4MiB
	if res.Status != StatusSuccess {
		t.Fatalf("res=%+v", res)
	}
}

func TestMemoryLimitAfterOutputFull(t *testing.T) {
	r := newRunner(t)
	// stdout으로 10240을 먼저 채운 뒤 OOM. stderr 응답은 비어도 분류 전용 tail로 memory_limit이어야 한다.
	res := run(t, r, wat(t, mem1, `(loop $l
	   (drop (call $w (i32.const 1) (i32.const 1024) (i32.const 1024)))
	   (local.set $i (i32.add (local.get $i) (i32.const 1)))
	   (br_if $l (i32.lt_u (local.get $i) (i32.const 20))))
	  (drop (memory.grow (i32.const 200)))
	  (drop (call $w (i32.const 2) (i32.const 32) (i32.const 38))) unreachable`))
	if res.Status != StatusMemoryLimit || !res.Truncated || res.Stderr != "" || len(res.Stdout) != OutputLimit {
		t.Fatalf("status=%s truncated=%v stdout=%d stderr=%q", res.Status, res.Truncated, len(res.Stdout), res.Stderr)
	}
}

func TestPlainUnreachableIsNotMemoryLimit(t *testing.T) {
	r := newRunner(t)
	res := run(t, r, wat(t, mem1, `(drop (call $w (i32.const 2) (i32.const 16) (i32.const 4))) unreachable`))
	if res.Status != StatusRuntimeError {
		t.Fatalf("res=%+v", res)
	}
}

func TestInitialMemoryOverLimit(t *testing.T) {
	r := newRunner(t)
	// 초기 메모리 200페이지(12.5MiB) > 10MiB → instantiate 실패도 memory_limit
	res := run(t, r, wat(t, `(memory (export "memory") 200)`, `nop`))
	if res.Status != StatusMemoryLimit {
		t.Fatalf("res=%+v", res)
	}
}

func TestIsAllocFailure(t *testing.T) {
	if !isAllocFailure([]byte("x\nmemory allocation of 100000000 bytes failed\nnote: run with")) {
		t.Error("alloc 메시지를 못 찾음")
	}
	for _, s := range []string{"", "panicked at memory allocation of", "bytes failed"} {
		if isAllocFailure([]byte(s)) {
			t.Errorf("%q 는 alloc 실패가 아님", s)
		}
	}
}

func TestStderrTailKeepsLast512(t *testing.T) {
	o := &output{}
	o.write(2, []byte(strings.Repeat("a", 600)))
	o.write(2, []byte("END"))
	if len(o.tail) != stderrTailSize || !strings.HasSuffix(string(o.tail), "aEND") {
		t.Fatalf("tail len=%d suffix=%q", len(o.tail), o.tail[len(o.tail)-4:])
	}
}

// 무한 루프는 5초 timeout, 같은 Engine에서 동시에 도는 정상 요청은 영향을 받지 않아야 한다 (요청 간 epoch 간섭 없음).
func TestTimeoutAndConcurrencyIsolation(t *testing.T) {
	if testing.Short() {
		t.Skip("5초 소요")
	}
	r := newRunner(t)
	loop := wat(t, mem1, `(loop $l (br $l))`)
	hello := wat(t, mem1, `(drop (call $w (i32.const 1) (i32.const 8) (i32.const 6)))`)

	var wg sync.WaitGroup
	var loopRes Result
	var loopDur time.Duration
	wg.Add(1)
	go func() {
		defer wg.Done()
		t0 := time.Now()
		loopRes = run(t, r, loop)
		loopDur = time.Since(t0)
	}()
	time.Sleep(2 * time.Second) // loop가 돌고 있는 동안
	for i := 0; i < 3; i++ {
		t0 := time.Now()
		res := run(t, r, hello)
		if res.Status != StatusSuccess || res.Stdout != "hello\n" || time.Since(t0) > time.Second {
			t.Fatalf("동시 hello #%d: %+v (%v)", i, res, time.Since(t0))
		}
	}
	// 두 번째 loop를 늦게 시작해도 deadline은 각자 시작 시점 기준이다
	var late Result
	var lateDur time.Duration
	wg.Add(1)
	go func() {
		defer wg.Done()
		t0 := time.Now()
		late = run(t, r, loop)
		lateDur = time.Since(t0)
	}()
	wg.Wait()
	for name, c := range map[string]struct {
		r Result
		d time.Duration
	}{"first": {loopRes, loopDur}, "late": {late, lateDur}} {
		if c.r.Status != StatusTimeout || c.r.ExitCode != -1 || c.d < 5*time.Second || c.d > 6*time.Second {
			t.Errorf("%s loop: %+v dur=%v (기대 timeout, 5~6s)", name, c.r, c.d)
		}
	}
}
