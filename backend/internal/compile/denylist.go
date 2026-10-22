package compile

import (
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Violation은 deny-list에 걸린 규칙이다 (F-M2-02). 소스 줄 내용은 담지 않는다 (응답으로 되돌려 보내지 않기 위해).
type Violation struct {
	Rule string
	Line int
	Desc string
}

// Message는 backend firstErrorLine이 요약 message로 쓰는 "error"로 시작하는 첫 줄이다.
func (v *Violation) Message() string {
	return fmt.Sprintf("error: LGTM 소스 정책 위반 [%s] %d행: %s\n", v.Rule, v.Line, v.Desc)
}

// gap은 토큰 사이에 올 수 있는 공백과 주석이다 (중첩 주석은 주석 제거 뷰가 푼다).
const gap = `(?:\s|/\*[\s\S]*?\*/|//[^\n]*)*`

type pattern struct {
	re *regexp.Regexp
	// noUse가 true면 use 문을 지운 텍스트에서 찾는다. `use std::{env, fs};` 같은 정상 import가
	// 인자 위치 패턴에 걸리지 않게 하려는 것이다. use 문은 매크로를 호출할 수 없고, 재명명은 deny-rename이 원문에서 잡는다.
	noUse bool
}

type rule struct {
	id   string
	desc string
	pats []pattern
}

func p(expr string) pattern      { return pattern{re: regexp.MustCompile(expr)} }
func pNoUse(expr string) pattern { return pattern{re: regexp.MustCompile(expr), noUse: true} }

// 규칙 순서가 곧 보고 우선순위다 (한 소스가 여러 규칙에 걸리면 첫 규칙만 보고한다).
var denyRules = []rule{
	{"deny-include-macro", "include!/include_str!/include_bytes!/option_env! 는 허용되지 않습니다 (파일 내용이 에러 메시지로 새는 경로)", []pattern{
		p(`\b(?:include_str|include_bytes|option_env)\b`),
		p(`\binclude` + gap + `!` + gap + `[(\[{]`),
		pNoUse(`[(,\[{]\s*(?:\w+::)*(?:r#)?include\s*[),\]}]`),
	}},
	{"deny-env-macro", "env! 는 허용되지 않습니다 (컴파일러 환경변수 노출). std::env 모듈 사용은 가능합니다", []pattern{
		p(`\benv` + gap + `!` + gap + `[(\[{]`),
		pNoUse(`[(,\[{]\s*(?:\w+::)*(?:r#)?env\s*[),\]}]`),
	}},
	{"deny-rename", "include/env 매크로 이름을 as 로 바꿔 가져오는 것은 허용되지 않습니다", []pattern{
		p(`\b(?:include|env)\b` + gap + `\bas\b`),
	}},
	{"deny-mod-file", "파일 모듈 선언(mod 이름;)은 허용되지 않습니다. 인라인 mod 이름 { ... } 를 쓰세요", []pattern{
		p(`\bmod\b` + gap + `(?:r#)?[\w$]+` + gap + `;`),
	}},
	{"deny-path-attr", "#[path] / cfg_attr(path = ...) 속성은 허용되지 않습니다", []pattern{
		p(`#\s*!?\s*\[[^\]]*\bpath\b`),
		p(`\bcfg_attr\b[^;{]*\bpath\s*=`),
	}},
	{"deny-incbin", ".incbin 어셈블러 지시어는 허용되지 않습니다 (파일 삽입)", []pattern{
		p(`\.incbin\b`),
	}},
}

var useStmt = regexp.MustCompile(`\buse\b[^;]*;`)

// CheckSource는 rustc 실행 전에 소스를 검사한다. 위반이 없으면 nil.
// raw 소스와 주석 제거 뷰 두 개를 모두 검사하고 한쪽이라도 걸리면 차단한다.
// 정규식 기반이라 문자열/주석 안의 같은 패턴도 차단한다 (오탐은 의도된 한계, 격리 계층이 최종 방어).
func CheckSource(src string) *Violation {
	views := []string{src, stripComments(src)}
	for _, r := range denyRules {
		for _, v := range views {
			noUse := ""
			for _, pt := range r.pats {
				text := v
				if pt.noUse {
					if noUse == "" {
						noUse = blank(useStmt, v)
					}
					text = noUse
				}
				if loc := pt.re.FindStringIndex(text); loc != nil {
					return &Violation{Rule: r.id, Line: 1 + strings.Count(text[:loc[0]], "\n"), Desc: r.desc}
				}
			}
		}
	}
	return nil
}

// blank는 re에 걸린 구간을 개행만 남기고 공백으로 바꾼다 (오프셋·행 번호 보존).
func blank(re *regexp.Regexp, s string) string {
	return re.ReplaceAllStringFunc(s, func(m string) string {
		b := []byte(m)
		for i, c := range b {
			if c != '\n' {
				b[i] = ' '
			}
		}
		return string(b)
	})
}

// stripComments는 주석(중첩 블록 주석 포함)을 공백으로 바꾼다. 개행은 보존한다.
// 문자열, raw string, char 리터럴 안의 `//`, `/*` 는 주석으로 보지 않는다.
// 완전한 Rust lexer가 아니다: 어긋나면 주석이 안 지워지거나(raw 뷰가 보완) 코드가 주석으로 오인될 수 있어,
// 결과는 raw 소스와 함께 검사하는 용도로만 쓴다.
func stripComments(s string) string {
	out := []byte(s)
	n := len(s)
	blankRange := func(a, b int) {
		for i := a; i < b && i < n; i++ {
			if out[i] != '\n' {
				out[i] = ' '
			}
		}
	}
	isIdent := func(c byte) bool {
		return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80
	}
	for i := 0; i < n; {
		c := s[i]
		switch {
		case c == '/' && i+1 < n && s[i+1] == '/':
			j := i
			for j < n && s[j] != '\n' {
				j++
			}
			blankRange(i, j)
			i = j
		case c == '/' && i+1 < n && s[i+1] == '*':
			depth, j := 1, i+2
			for j < n && depth > 0 {
				switch {
				case s[j] == '/' && j+1 < n && s[j+1] == '*':
					depth++
					j += 2
				case s[j] == '*' && j+1 < n && s[j+1] == '/':
					depth--
					j += 2
				default:
					j++
				}
			}
			blankRange(i, j)
			i = j
		case c == 'r' && (i == 0 || !isIdent(s[i-1])) && rawStringEnd(s, i+1) > 0,
			c == 'b' && (i == 0 || !isIdent(s[i-1])) && i+1 < n && s[i+1] == 'r' && rawStringEnd(s, i+2) > 0:
			start := i + 1
			if c == 'b' {
				start = i + 2
			}
			i = rawStringEnd(s, start)
		case c == '"':
			i++
			for i < n && s[i] != '"' {
				if s[i] == '\\' {
					i++
				}
				i++
			}
			i++
		case c == '\'':
			// char 리터럴('x', '\n', '한') 이면 닫는 따옴표까지 건너뛰고, 아니면 lifetime이다.
			if i+1 < n && s[i+1] == '\\' {
				j := i + 2
				for j < n && s[j] != '\'' && s[j] != '\n' {
					j++
				}
				i = j + 1
			} else if i+1 < n {
				_, w := utf8.DecodeRuneInString(s[i+1:])
				if i+1+w < n && s[i+1+w] == '\'' {
					i += w + 2
				} else {
					i++
				}
			} else {
				i++
			}
		default:
			i++
		}
	}
	return string(out)
}

// rawStringEnd는 s[at:]이 `#*"` 로 시작하는 raw string이면 닫는 `"#*` 다음 위치를, 아니면 0을 반환한다.
func rawStringEnd(s string, at int) int {
	j := at
	for j < len(s) && s[j] == '#' {
		j++
	}
	if j >= len(s) || s[j] != '"' {
		return 0
	}
	closer := "\"" + strings.Repeat("#", j-at)
	k := strings.Index(s[j+1:], closer)
	if k < 0 {
		return len(s)
	}
	return j + 1 + k + len(closer)
}
