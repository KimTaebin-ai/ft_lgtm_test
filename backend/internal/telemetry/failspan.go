package telemetry

import (
	"errors"
	"unicode/utf8"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// MaxSpanMessageBytes는 span status description과 error event message의 상한이다.
const MaxSpanMessageBytes = 512

// Classified는 사용자 입력에서 나온 문자열이 없는 분류형 문구(예: "rustc failed [E0425]")를 돌려주는 에러다.
// span/event/로그에는 err.Error() 대신 이 문구만 쓴다. 원문(rustc 메시지, panic 메시지)은 응답과 IPFS 결과에만 있다.
type Classified interface{ SpanMessage() string }

// ClassOf는 err 체인에서 분류형 문구를 찾는다. 없으면 ("", false).
func ClassOf(err error) (string, bool) {
	var c Classified
	if errors.As(err, &c) {
		return c.SpanMessage(), true
	}
	return "", false
}

// FailSpan은 span을 ERROR로 표시하고 error event를 남긴다. class는 고정 분류 문구여야 한다.
// event에는 exception.message 하나만 넣는다 (exception.type, stacktrace 없음). status description과 event 모두 512바이트로 자른다.
func FailSpan(span trace.Span, class string) {
	class = truncateUTF8(class, MaxSpanMessageBytes)
	span.SetStatus(codes.Error, class)
	span.AddEvent("exception", trace.WithAttributes(attribute.String("exception.message", class)))
}

// truncateUTF8은 UTF-8 경계를 지키며 max바이트 이하로 자른다.
func truncateUTF8(s string, max int) string {
	if len(s) <= max {
		return s
	}
	s = s[:max]
	for len(s) > 0 && !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}
