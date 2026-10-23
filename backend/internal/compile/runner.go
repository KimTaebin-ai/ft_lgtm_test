// Package compile은 rustc를 요청마다 격리된 임시 디렉토리에서 실행한다 (F-M2-01).
// 동시 실행 수 제한(semaphore), 15초 timeout, 프로세스 그룹 kill, 임시 디렉토리 삭제를 담당한다.
package compile

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

const (
	// DefaultTimeout은 SEC-07의 compile 제한 시간. semaphore 획득 이후부터 센다.
	DefaultTimeout = 15 * time.Second
	// DefaultConcurrency는 SEC-07: pod 안 동시 compile 수.
	DefaultConcurrency = 2

	maxStderrBytes = 64 << 10
	waitDelay      = 2 * time.Second
	srcName        = "main.rs"
	outName        = "out.wasm"
)

// ErrTimeout은 rustc가 제한 시간 안에 끝나지 않아 프로세스 그룹을 kill했음을 뜻한다.
var ErrTimeout = errors.New("compile timeout")

// CompileError는 rustc가 0이 아닌 코드로 종료한 경우(사용자 코드 오류)다.
type CompileError struct {
	Stderr   string
	ExitCode int // rustc 종료 코드
}

func (e *CompileError) Error() string { return "rustc failed" }

// CmdFunc는 dir 안에서 실행할 명령을 만든다. 테스트에서 느린 명령을 주입하는 용도.
// Runner가 Dir, SysProcAttr, Cancel, WaitDelay, Stderr를 덮어쓴다.
type CmdFunc func(ctx context.Context, dir string) *exec.Cmd

// Runner는 compile 요청을 처리한다. 값은 NewRunner로 만든다.
type Runner struct {
	WorkDir string
	Timeout time.Duration
	NewCmd  CmdFunc
	Log     *slog.Logger

	sem chan struct{}
}

func NewRunner(log *slog.Logger, workDir string, concurrency int) *Runner {
	return &Runner{WorkDir: workDir, Timeout: DefaultTimeout, NewCmd: RustcCmd, Log: log, sem: make(chan struct{}, concurrency)}
}

// RustcCmd는 wasm32-wasip1 대상 rustc 명령이다. edition 2021은 널리 쓰이는 예제 코드와 호환되고
// 2024의 예약어/unsafe extern 변경 위험을 피하려고 고정했다 (rustc 1.99.1 기준).
func RustcCmd(ctx context.Context, dir string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "rustc",
		"--edition", "2021",
		"--target", "wasm32-wasip1",
		"-C", "opt-level=1",
		"--crate-type", "bin",
		"--crate-name", "main",
		"-o", outName,
		srcName,
	)
	cmd.Dir = dir // 상대 경로로 넘겨 rustc 에러 메시지에 임시 디렉토리 경로(req-XXXX)가 새지 않게 한다
	cmd.Env = rustcEnv(dir)
	return cmd
}

// rustcEnv는 rustc에 넘기는 환경변수 전체다. 명시한 5개만 전달하고 프로세스 환경은 상속하지 않는다 (env -i 동등).
// 소스가 env!/option_env!/std::env 로 읽어도 다른 Service 주소나 비밀값이 없게 하려는 것이다 (F-M2-02).
func rustcEnv(dir string) []string {
	return []string{
		"PATH=" + os.Getenv("PATH"),
		"RUSTUP_HOME=" + os.Getenv("RUSTUP_HOME"),
		"CARGO_HOME=" + os.Getenv("CARGO_HOME"),
		"HOME=" + dir,
		"TMPDIR=" + dir,
	}
}

// Run은 src를 컴파일해 wasm 바이트를 반환한다. 반환 에러는 *CompileError, ErrTimeout, ctx 에러, 그 외(내부 오류) 중 하나다.
// 대기 시간(queue wait)도 반환한다. semaphore가 가득 차면 거부하지 않고 기다린다 (거부는 F-M2-04에서 backend가 담당).
func (r *Runner) Run(ctx context.Context, src []byte) (wasm []byte, wait time.Duration, err error) {
	t0 := time.Now()
	select {
	case r.sem <- struct{}{}:
	case <-ctx.Done():
		return nil, time.Since(t0), ctx.Err()
	}
	defer func() { <-r.sem }()
	wait = time.Since(t0)

	r.Log.InfoContext(ctx, "compile started", "queue_wait_ms", wait.Milliseconds())
	defer func() { r.Log.InfoContext(ctx, "compile finished", "ok", err == nil) }()

	// 성공/실패/timeout/panic 모두 defer로 삭제한다. wasm은 삭제 전에 메모리로 읽는다.
	dir, err := os.MkdirTemp(r.WorkDir, "req-")
	if err != nil {
		return nil, wait, err
	}
	defer os.RemoveAll(dir)
	if err := os.WriteFile(filepath.Join(dir, srcName), src, 0o600); err != nil {
		return nil, wait, err
	}

	cctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()
	cmd := r.NewCmd(cctx, dir)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // rustc와 그 자식(linker 등)을 한 프로세스 그룹으로
	cmd.Cancel = func() error { return killGroup(cmd) }
	cmd.WaitDelay = waitDelay // 자식이 pipe를 쥐고 있어도 Wait가 무한정 막히지 않게 한다
	var stderr limitedBuffer
	cmd.Stderr = &stderr

	runErr := cmd.Run()
	switch {
	case cctx.Err() != nil && ctx.Err() == nil: // 우리 timeout
		_ = killGroup(cmd) // Cancel 이후 남은 그룹원 정리
		return nil, wait, ErrTimeout
	case ctx.Err() != nil: // 요청 취소
		_ = killGroup(cmd)
		return nil, wait, ctx.Err()
	}
	var ee *exec.ExitError
	if errors.As(runErr, &ee) {
		return nil, wait, &CompileError{Stderr: stderr.String(), ExitCode: ee.ExitCode()}
	}
	if runErr != nil {
		return nil, wait, runErr
	}
	wasm, err = os.ReadFile(filepath.Join(dir, outName))
	return wasm, wait, err
}

// killGroup은 cmd의 프로세스 그룹 전체에 SIGKILL을 보낸다 (Setpgid라 pgid == pid).
func killGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	if errors.Is(err, syscall.ESRCH) {
		return nil
	}
	return err
}

// limitedBuffer는 maxStderrBytes까지만 보관하고 나머지는 버린다 (pipe는 계속 비운다).
type limitedBuffer struct{ buf bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if room := maxStderrBytes - b.buf.Len(); room > 0 {
		b.buf.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

func (b *limitedBuffer) String() string { return b.buf.String() }
