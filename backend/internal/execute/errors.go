package execute

import (
	"context"
	"errors"
	"net"

	"lgtm/backend/internal/ipfs"
	"lgtm/backend/internal/telemetry"
)

// 단계 실패 에러와 span 문구 규칙 (TR-02).
// span status / error event / 로그에는 telemetry.Classified의 SpanMessage()(분류형 문구)만 쓴다.
// Error()는 사용자 입력(rustc 메시지, panic 메시지)이 섞일 수 있어 응답과 IPFS 결과에만 쓴다.
// userError와 execFailure는 사용자 입력 유래라 Error()를 로그에도 쓰지 않는다 (failClass의 userDerived).
var (
	_ telemetry.Classified = (*userError)(nil)
	_ telemetry.Classified = (*uploadError)(nil)
	_ telemetry.Classified = (*execFailure)(nil)
)

// userError는 사용자 코드가 원인인 compile 실패(rustc 에러, 15초 timeout)다 → status compile_error.
// 이 타입이 아닌 에러(연결 실패, 그 외 5xx, wasm 크기 초과)는 플랫폼 문제로 보고 internal_error가 된다.
type userError struct {
	Message string
	Stderr  string
	// Class는 span/event/로그에 쓰는 분류형 문구다. Message(rustc 첫 줄)는 사용자 식별자를 인용할 수 있어 쓰지 않는다.
	Class string
}

func (e *userError) Error() string { return e.Message }

// SpanMessage는 telemetry.Classified를 구현한다.
func (e *userError) SpanMessage() string { return e.Class }

// uploadError는 ipfs.upload 실패다. 분류는 timeout/connect/http_4xx/http_5xx/other 중 하나다.
// 내용(Kubo 응답 본문 등)은 사용자 입력이 아니지만 span에는 분류만 둔다.
type uploadError struct{ err error }

func (e *uploadError) Error() string { return "ipfs upload: " + e.err.Error() }
func (e *uploadError) Unwrap() error { return e.err }
func (e *uploadError) SpanMessage() string {
	var se *ipfs.StatusError
	var ne net.Error
	switch {
	case errors.Is(e.err, context.DeadlineExceeded):
		return "ipfs upload failed [timeout]"
	case errors.As(e.err, &se) && se.Code >= 500:
		return "ipfs upload failed [http_5xx]"
	case errors.As(e.err, &se):
		return "ipfs upload failed [http_4xx]"
	case errors.As(e.err, &ne):
		return "ipfs upload failed [connect]"
	}
	return "ipfs upload failed [other]"
}

// execFailure는 사용자 코드의 실행 실패(runtime_error/timeout/memory_limit)다. execute span을 ERROR로 만들기 위해
// step의 error로 돌려주지만, 플랫폼 오류(internal_error)와 구분한다.
type execFailure struct{ msg, class string }

func (e *execFailure) Error() string       { return e.msg }
func (e *execFailure) SpanMessage() string { return e.class }

// failClass는 err의 분류형 문구를 돌려준다. 분류가 없는 오류는 플랫폼 오류로 보고 "internal error [단계]"다.
// userDerived가 true면 err 문자열에 사용자 입력이 들어 있을 수 있으므로 로그에 쓰면 안 된다.
func failClass(err error, stage string) (cls string, userDerived bool) {
	var ue *userError
	var ef *execFailure
	userDerived = errors.As(err, &ue) || errors.As(err, &ef)
	if c, ok := telemetry.ClassOf(err); ok && c != "" {
		return c, userDerived
	}
	return "internal error [" + stage + "]", userDerived
}
