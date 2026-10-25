// Package wasmexec는 compile이 만든 wasm을 wasmtime-go로 sandbox 실행한다.
//
// 요청마다 Store를 새로 만들고 Engine/Linker는 공유한다.
//   - capability 0: preopen 없음, 환경변수 없음, argv는 프로그램 이름 하나, stdin 없음, socket 없음.
//   - memory: Store.Limiter로 10MiB.
//   - time: epoch interruption. Engine 전체에 하나뿐인 ticker가 epoch를 올리고, Store마다 deadline을 둔다.
//     IncrementEpoch는 Engine 전체에 적용되므로 요청마다 타이머로 올리면 동시에 실행 중인 다른 요청이 끊긴다.
//   - output: wasmtime-go의 stdout/stderr는 파일 경로(SetStdoutFile)뿐이라 디스크에 무제한 쓸 수 있다.
//     그래서 wasi_snapshot_preview1.fd_write를 Go 함수로 shadowing해 fd 1, 2를 메모리 버퍼로만 받는다.
package wasmexec

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	wasmtime "github.com/bytecodealliance/wasmtime-go/v50"
)

const (
	// MemoryLimit은 모듈 메모리 상한 10MiB.
	MemoryLimit = 10 << 20
	// Timeout은 실행 wall-clock 상한이다.
	Timeout = 5 * time.Second
	// OutputLimit은 stdout+stderr 합계 상한.
	OutputLimit = 10240

	// tick마다 전역 epoch를 1 올린다. deadline은 Timeout/tick + 1 이다.
	// ticker 위상 때문에 deadline 직전 tick이 최대 한 tick 일찍 올 수 있어 +1로 5초 이상을 보장한다.
	tick          = 100 * time.Millisecond
	epochDeadline = uint64(Timeout/tick) + 1

	// stderrTailSize는 응답과 별개로 분류 전용으로 보관하는 stderr 마지막 바이트 수다.
	// 출력이 10kB를 먼저 채운 뒤 OOM이 나도 alloc 실패 메시지를 볼 수 있게 한다.
	stderrTailSize = 512

	wasiModule = "wasi_snapshot_preview1"
	errnoBadf  = 8
	errnoFault = 21
)

// 실행 결과 status. handler의 응답 status와 같은 문자열이다.
const (
	StatusSuccess      = "success"
	StatusRuntimeError = "runtime_error"
	StatusTimeout      = "timeout"
	StatusMemoryLimit  = "memory_limit"
)

// Result는 한 번의 실행 결과다. 플랫폼 오류(엔진 생성 실패 등)는 Run의 error로 반환한다.
type Result struct {
	Status  string
	Message string // runtime_error 등의 한 줄 요약. 응답 message에 쓴다.
	// Class는 span/event/로그에 쓰는 분류형 문구다. Message와 달리 사용자 입력(panic 메시지, trap backtrace의 함수명)이 없다.
	Class     string
	Stdout    string
	Stderr    string
	Truncated bool
	// ExitCode는 프로세스 종료 코드다. trap/timeout처럼 종료 코드가 없으면 -1.
	ExitCode int
}

// Runner는 Engine과 Linker를 공유하고 전역 epoch ticker를 돌린다.
type Runner struct {
	engine *wasmtime.Engine
	linker *wasmtime.Linker
	stop   chan struct{}
	done   chan struct{}
	once   sync.Once
}

// New는 Runner를 만들고 ticker를 시작한다. 쓴 뒤에는 Close를 호출해야 한다.
func New() (*Runner, error) {
	cfg := wasmtime.NewConfig()
	cfg.SetEpochInterruption(true)
	engine := wasmtime.NewEngineWithConfig(cfg)

	linker := wasmtime.NewLinker(engine)
	if err := linker.DefineWasi(); err != nil {
		return nil, fmt.Errorf("DefineWasi: %w", err)
	}
	// fd_write만 재정의한다 (wasmtime-go v50 linker.go AllowShadowing).
	linker.AllowShadowing(true)
	if err := linker.FuncWrap(wasiModule, "fd_write", fdWrite); err != nil {
		return nil, fmt.Errorf("fd_write 재정의: %w", err)
	}

	r := &Runner{engine: engine, linker: linker, stop: make(chan struct{}), done: make(chan struct{})}
	go r.ticker()
	return r, nil
}

func (r *Runner) ticker() {
	defer close(r.done)
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			r.engine.IncrementEpoch()
		case <-r.stop:
			return
		}
	}
}

// Close는 ticker를 멈춘다. 실행 중인 요청이 없을 때 호출한다.
func (r *Runner) Close() {
	r.once.Do(func() { close(r.stop); <-r.done })
}

// output은 요청 하나의 stdout/stderr 버퍼다. 합계가 OutputLimit을 넘는 바이트는 버린다.
type output struct {
	stdout, stderr bytes.Buffer
	truncated      bool
	tail           []byte // stderr 전체 스트림의 마지막 stderrTailSize 바이트 (분류 전용)
}

func (o *output) write(fd int32, p []byte) {
	if fd == 2 {
		o.tail = append(o.tail, p...)
		if len(o.tail) > stderrTailSize {
			o.tail = append(o.tail[:0], o.tail[len(o.tail)-stderrTailSize:]...)
		}
	}
	room := OutputLimit - o.stdout.Len() - o.stderr.Len()
	if len(p) > room {
		p = p[:max(room, 0)]
		o.truncated = true
	}
	if fd == 1 {
		o.stdout.Write(p)
	} else {
		o.stderr.Write(p)
	}
}

// fdWrite는 WASI fd_write다. fd 1, 2만 받고 나머지는 EBADF.
// nwritten에는 버린 바이트까지 요청 전체를 기록해서 프로그램이 정상 진행하게 한다.
func fdWrite(c *wasmtime.Caller, fd, iovs, iovsLen, nwrittenPtr int32) int32 {
	if fd != 1 && fd != 2 {
		return errnoBadf
	}
	out, ok := c.Data().(*output)
	if !ok {
		return errnoBadf
	}
	ext := c.GetExport("memory")
	if ext == nil || ext.Memory() == nil {
		return errnoFault
	}
	mem := ext.Memory().UnsafeData(c)
	var total uint32
	for i := uint32(0); i < uint32(iovsLen); i++ {
		base := uint64(uint32(iovs)) + uint64(i)*8
		if base+8 > uint64(len(mem)) {
			return errnoFault
		}
		ptr := uint64(binary.LittleEndian.Uint32(mem[base:]))
		n := uint64(binary.LittleEndian.Uint32(mem[base+4:]))
		if ptr+n > uint64(len(mem)) {
			return errnoFault
		}
		out.write(fd, mem[ptr:ptr+n])
		total += uint32(n)
	}
	if uint64(uint32(nwrittenPtr))+4 > uint64(len(mem)) {
		return errnoFault
	}
	binary.LittleEndian.PutUint32(mem[uint32(nwrittenPtr):], total)
	return 0
}

// Run은 wasm의 _start를 실행한다. 사용자 코드 때문에 생기는 실패는 Result.Status로, 플랫폼 오류는 error로 돌려준다.
func (r *Runner) Run(wasm []byte) (Result, error) {
	mod, err := wasmtime.NewModule(r.engine, wasm)
	if err != nil {
		return Result{}, fmt.Errorf("wasm 모듈 로드 실패: %w", err)
	}
	defer mod.Close()

	out := &output{}
	store := wasmtime.NewStoreWithData(r.engine, out)
	defer store.Close()
	store.Limiter(MemoryLimit, -1, -1, -1, -1)
	store.SetEpochDeadline(epochDeadline)
	wc := wasmtime.NewWasiConfig()
	wc.SetArgv([]string{"main"})
	store.SetWasi(wc)

	inst, err := r.linker.Instantiate(store, mod)
	if err != nil {
		if isMemoryLimitError(err) {
			return Result{Status: StatusMemoryLimit, Message: "memory limit exceeded", Class: classMemory, ExitCode: -1}, nil
		}
		return Result{}, fmt.Errorf("instantiate 실패: %w", err)
	}
	start := inst.GetFunc(store, "_start")
	if start == nil {
		return Result{}, errors.New("_start export 없음")
	}

	_, callErr := start.Call(store)
	res := Result{Status: StatusSuccess, ExitCode: 0}
	if callErr != nil {
		res = classify(callErr, out.tail)
	}
	res.Stdout = out.stdout.String()
	res.Stderr = out.stderr.String()
	res.Truncated = out.truncated
	return res, nil
}

// classify는 _start의 에러를 status로 매핑한다.
//   - WASI proc_exit: 0이면 success, 아니면 runtime_error
//   - epoch deadline: trap Interrupt → timeout
//   - memory.grow 거부: Store.Limiter는 거부 콜백이 없다. grow가 -1을 돌려주면 Rust가 alloc 실패 메시지를 stderr에 쓰고
//     abort(unreachable trap)한다. 그래서 unreachable trap + stderr 꼬리의 alloc 실패 메시지로 판별한다 (휴리스틱).
//   - 그 외 trap(panic=abort도 unreachable): runtime_error
func classify(err error, stderrTail []byte) Result {
	var werr *wasmtime.Error
	if errors.As(err, &werr) {
		if code, ok := werr.ExitStatus(); ok {
			if code == 0 {
				return Result{Status: StatusSuccess, ExitCode: 0}
			}
			return Result{Status: StatusRuntimeError, Message: fmt.Sprintf("exit status %d", code), Class: fmt.Sprintf("exit code %d", code), ExitCode: int(code)}
		}
	}
	var trap *wasmtime.Trap
	if errors.As(err, &trap) {
		if c := trap.Code(); c != nil {
			switch *c {
			case wasmtime.Interrupt:
				return Result{Status: StatusTimeout, Message: "time limit exceeded (5s)", Class: "time limit exceeded", ExitCode: -1}
			case wasmtime.UnreachableCodeReached:
				if isAllocFailure(stderrTail) {
					return Result{Status: StatusMemoryLimit, Message: "memory limit exceeded", Class: classMemory, ExitCode: -1}
				}
			}
		}
		return Result{Status: StatusRuntimeError, Message: "trap: " + lastLine(trap.Message()), Class: "wasm trap [" + trapName(trap) + "]", ExitCode: -1}
	}
	return Result{Status: StatusRuntimeError, Message: lastLine(err.Error()), Class: "runtime error", ExitCode: -1}
}

const classMemory = "memory limit exceeded"

// trapNames는 wasmtime TrapCode의 고정 이름이다. backtrace(사용자 함수명 포함)나 Message()는 쓰지 않는다.
var trapNames = map[wasmtime.TrapCode]string{
	wasmtime.StackOverflow:          "stack_overflow",
	wasmtime.MemoryOutOfBounds:      "memory_out_of_bounds",
	wasmtime.HeapMisaligned:         "heap_misaligned",
	wasmtime.TableOutOfBounds:       "table_out_of_bounds",
	wasmtime.IndirectCallToNull:     "indirect_call_to_null",
	wasmtime.BadSignature:           "bad_signature",
	wasmtime.IntegerOverflow:        "integer_overflow",
	wasmtime.IntegerDivisionByZero:  "integer_division_by_zero",
	wasmtime.BadConversionToInteger: "bad_conversion_to_integer",
	wasmtime.UnreachableCodeReached: "unreachable",
	wasmtime.Interrupt:              "interrupt",
	wasmtime.OutOfFuel:              "out_of_fuel",
}

func trapName(t *wasmtime.Trap) string {
	if c := t.Code(); c != nil {
		if n, ok := trapNames[*c]; ok {
			return n
		}
	}
	return "unknown"
}

// isAllocFailure는 Rust std의 기본 alloc error handler 메시지("memory allocation of N bytes failed")를 찾는다.
// 사용자가 같은 문자열을 출력하고 abort하면 memory_limit으로 위장할 수 있다 (status 라벨만 영향, 보안 경계 아님).
func isAllocFailure(tail []byte) bool {
	i := bytes.LastIndex(tail, []byte("memory allocation of "))
	return i >= 0 && bytes.Contains(tail[i:], []byte(" bytes failed"))
}

// isMemoryLimitError는 초기 메모리가 Limiter 상한을 넘어 instantiate가 실패한 경우를 판별한다.
func isMemoryLimitError(err error) bool {
	m := strings.ToLower(err.Error())
	return strings.Contains(m, "memory") && (strings.Contains(m, "exceeds") || strings.Contains(m, "limit") || strings.Contains(m, "minimum"))
}

// lastLine은 wasmtime 에러의 마지막 줄을 쓴다. 앞쪽은 backtrace라 "wasm trap: ..." 사유가 마지막에 온다.
func lastLine(s string) string {
	s = strings.TrimSpace(s)
	return s[strings.LastIndex(s, "\n")+1:]
}
