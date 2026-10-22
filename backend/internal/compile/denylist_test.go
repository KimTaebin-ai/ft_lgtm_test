package compile

import (
	"strings"
	"testing"
)

func TestCheckSourceBlocks(t *testing.T) {
	cases := []struct{ name, rule, src string }{
		{"include_str", "deny-include-macro", `fn main() { println!("{}", include_str!("/etc/passwd")); }`},
		{"include_str 공백", "deny-include-macro", `fn main() { include_str !("/etc/passwd"); }`},
		{"include_str 개행", "deny-include-macro", "fn main() { include_str\n!(\"/etc/passwd\"); }"},
		{"include_bytes", "deny-include-macro", `fn main() { include_bytes!("/etc/passwd"); }`},
		{"option_env", "deny-include-macro", `fn main() { option_env!("PATH"); }`},
		{"core 경로", "deny-include-macro", `fn main() { core::include_str!("/etc/passwd"); }`},
		{"std 경로 공백", "deny-include-macro", `fn main() { std :: include_str !("/etc/passwd"); }`},
		{"raw ident", "deny-include-macro", `fn main() { r#include_str!("/etc/passwd"); }`},
		{"as 재명명", "deny-include-macro", `use std::include_str as x; fn main() { x!("/etc/passwd"); }`},
		{"macro_rules 래핑", "deny-include-macro", `macro_rules! m { () => { include_str!("/etc/passwd") }; } fn main() { m!(); }`},
		{"ident 매개변수 include_str", "deny-include-macro", `macro_rules! m { ($n:ident) => { $n!("/etc/passwd") }; } fn main() { m!(include_str); }`},
		{"include", "deny-include-macro", `fn main() { let _ = include!("/etc/passwd"); }`},
		{"include 경로", "deny-include-macro", `fn main() { let _ = std::include!("/etc/passwd"); }`},
		{"ident 매개변수 include", "deny-include-macro", `macro_rules! m { ($n:ident) => { $n!("/etc/passwd") }; } fn main() { m!(include); }`},
		{"블록 주석 gap", "deny-include-macro", `fn main() { include /* x */ !("/etc/passwd"); }`},
		{"중첩 주석 gap", "deny-include-macro", `fn main() { include_str /* /* */ */ !("/etc/passwd"); }`},
		{"중첩 주석 gap include", "deny-include-macro", `fn main() { include /* /* */ */ !("/etc/passwd"); }`},
		{"문자열 // 뒤 중첩 주석", "deny-include-macro", `fn main() { let s = "//"; include /* /* */ */ !("/etc/passwd"); }`},
		{"env", "deny-env-macro", `fn main() { env!("PATH"); }`},
		{"env 공백", "deny-env-macro", `fn main() { env !("PATH"); }`},
		{"std::env!", "deny-env-macro", `fn main() { std::env!("PATH"); }`},
		{"std::r#env!", "deny-env-macro", `fn main() { std::r#env!("PATH"); }`},
		{"ident 매개변수 env", "deny-env-macro", `macro_rules! m { ($n:ident) => { $n!("PATH") }; } fn main() { m!(env); }`},
		{"ident 매개변수 r#env", "deny-env-macro", `macro_rules! m { ($n:ident) => { $n!("PATH") }; } fn main() { m!(r#env); }`},
		{"ident 매개변수 경로 env", "deny-env-macro", `fn main() { m!(a, std::env); }`},
		{"env as", "deny-rename", `use std::env as e; fn main() { e!("PATH"); }`},
		{"use 묶음 env as", "deny-rename", `use std::{env as e}; fn main() {}`},
		{"mod 파일", "deny-mod-file", `mod x; fn main() {}`},
		{"mod 주석 gap", "deny-mod-file", `mod x /* c */ ; fn main() {}`},
		{"mod macro_rules", "deny-mod-file", `macro_rules! m { ($n:ident) => { mod $n; }; } fn main() {}`},
		{"path 속성", "deny-mod-file", `#[path = "/proc/self/environ"] mod x; fn main() {}`},
		{"path 속성만", "deny-path-attr", `#[path = "/proc/self/environ"] fn main() {}`},
		{"cfg_attr path", "deny-mod-file", `#[cfg_attr(all(), path = "/proc/self/environ")] mod x; fn main() {}`},
		{"cfg_attr path만", "deny-path-attr", `#[cfg_attr(all(), path = "/x")] fn main() {}`},
		{"incbin", "deny-incbin", `fn main() { let _ = ".incbin \"/etc/passwd\""; }`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := CheckSource(c.src)
			if v == nil {
				t.Fatalf("차단되지 않음: %s", c.src)
			}
			if v.Rule != c.rule {
				t.Errorf("rule=%s, 기대 %s", v.Rule, c.rule)
			}
		})
	}
}

func TestCheckSourceAllows(t *testing.T) {
	cases := map[string]string{
		"struct/trait/iterator": `use std::collections::HashMap;
trait Shape { fn area(&self) -> f64; }
struct Sq(f64);
impl Shape for Sq { fn area(&self) -> f64 { self.0 * self.0 } }
fn main() { let v: Vec<u32> = (1..10).filter(|x| x % 2 == 0).collect(); println!("{:?} {}", v, Sq(2.0).area()); }`,
		"std::env::args":     `fn main() { let a: Vec<String> = std::env::args().collect(); println!("{}", a.len()); }`,
		"use std::env":       `use std::env; fn main() { println!("{}", env::args().count()); }`,
		"use 묶음 env":         `use std::{env, fs}; fn main() { let _ = (env::args().count(), fs::metadata("/")); }`,
		"use 묶음 앞 env":       `use std::{fs, env}; fn main() { let _ = env::args(); }`,
		"env::var":           `fn main() { let _ = std::env::var("HOME"); }`,
		"env 비교":             `fn main() { let env = 1; if env != 2 { println!("x"); } }`,
		"인라인 mod":            `mod inner { pub fn f() -> u32 { 1 } } fn main() { println!("{}", inner::f()); }`,
		"path 변수":            `fn main() { let path = "a/b"; println!("{}", path); }`,
		"lifetime과 char":     `fn f<'a>(s: &'a str) -> &'a str { s } fn main() { let c = '/'; println!("{}{}", f("x"), c); }`,
		"일반 주석":              "// include 는 쓰지 않는다\nfn main() {}",
		"mod 포함 이름":          `fn model() {} fn main() { model(); }`,
		"modulo 이름 변수 modes": `fn main() { let modes = 3; println!("{}", modes % 2); }`,
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			if v := CheckSource(src); v != nil {
				t.Errorf("정상 코드가 차단됨: %s", v.Message())
			}
		})
	}
}

func TestCheckSourceKnownFalsePositives(t *testing.T) {
	// 한계: 문자열/주석 안의 패턴도 차단한다 (HANDOFF 기록). 동작을 고정해 둔다.
	for name, src := range map[string]string{
		"문자열 안":  `fn main() { println!("include_str!"); }`,
		"주석 안":   "// env!(\"X\")\nfn main() {}",
		"f(env)": `fn main() { let env = 1; f(env); }`,
	} {
		if CheckSource(src) == nil {
			t.Errorf("%s: 오탐 한계 동작이 바뀜 (문서 갱신 필요)", name)
		}
	}
}

func TestViolationMessageFormatAndLine(t *testing.T) {
	v := CheckSource("fn main() {\n\n    let _ = include_str!(\"/etc/passwd\");\n}")
	if v == nil || v.Line != 3 {
		t.Fatalf("v=%+v, 기대 3행", v)
	}
	m := v.Message()
	if !strings.HasPrefix(m, "error: LGTM 소스 정책 위반 [deny-include-macro] 3행: ") || strings.Contains(m, "passwd") {
		t.Errorf("message=%q", m)
	}
}

func TestStripCommentsKeepsLayout(t *testing.T) {
	src := "a /* x /* y\n */ z */ b // c\n\"//\" d 'q' 'a r\"/*\"# e"
	out := stripComments(src)
	if len(out) != len(src) || strings.Count(out, "\n") != strings.Count(src, "\n") {
		t.Fatalf("길이/행 수가 달라짐: %q", out)
	}
	if strings.Contains(out, "x") || strings.Contains(out, "y") || strings.Contains(out, " c") {
		t.Errorf("주석이 남음: %q", out)
	}
	if !strings.Contains(out, `"//"`) {
		t.Errorf("문자열 안 // 가 지워짐: %q", out)
	}
}
