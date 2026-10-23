package execute

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"

	"lgtm/backend/internal/ipfs"
	"lgtm/backend/internal/wasmexec"
)

// 업로드 디렉토리의 파일 이름은 고정 3개다. 사용자 입력은 경로에 들어가지 않는다 (PRD IP-02).
const (
	fileMain   = "main.rs"
	fileOutput = "output.txt"
	fileStatus = "status.json"
)

// status.json 에 넣는 컴파일러 정보. 같은 코드·결과면 같은 CID 가 나와야 하므로 요청마다 달라지는 값
// (timestamp, trace_id, 요청 ID, timings)은 넣지 않는다.
// rustcVersion 은 backend/Dockerfile.compiler 의 rust 이미지 태그와 같아야 한다 (scripts/verify/m3-02-ipfs-upload.sh 가 비교한다).
const (
	rustcVersion = "1.99.1"
	rustEdition  = "2021" // backend/internal/compile/runner.go 의 --edition
)

// statusDoc 의 필드 순서가 곧 status.json 의 key 순서다. ExitCode 가 nil 이면 null (실행 전에 끝난 compile_error 등).
type statusDoc struct {
	Status    string `json:"status"`
	Message   string `json:"message"`
	ExitCode  *int   `json:"exit_code"`
	Truncated bool   `json:"truncated"`
	Language  string `json:"language"`
	Edition   string `json:"edition"`
	Rustc     string `json:"rustc"`
}

// buildFiles 는 응답으로 보낼 결과를 IPFS 디렉토리 파일 3개로 만든다. 순수 함수이며 같은 입력이면 바이트까지 같다.
func buildFiles(code string, resp response, exitCode *int) []ipfs.File {
	return []ipfs.File{
		{Name: fileMain, Data: []byte(code)},
		{Name: fileOutput, Data: []byte(outputText(resp.Stdout, resp.Stderr, resp.Truncated))},
		{Name: fileStatus, Data: statusJSON(resp, exitCode)},
	}
}

// outputText 는 stdout 과 stderr 를 구분 줄로 나눠 담는다. 섹션 내용이 비어 있지 않고 개행으로 끝나지 않으면 개행을 붙인다.
// truncated 이면 마지막에 한 줄 표시한다.
func outputText(stdout, stderr string, truncated bool) string {
	var b strings.Builder
	b.WriteString("--- stdout ---\n")
	writeSection(&b, stdout)
	b.WriteString("--- stderr ---\n")
	writeSection(&b, stderr)
	if truncated {
		b.WriteString("--- truncated: output exceeded " + strconv.Itoa(wasmexec.OutputLimit) + " bytes ---\n")
	}
	return b.String()
}

func writeSection(b *strings.Builder, s string) {
	b.WriteString(s)
	if s != "" && !strings.HasSuffix(s, "\n") {
		b.WriteByte('\n')
	}
}

func statusJSON(resp response, exitCode *int) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	// 인코딩 실패는 이 타입으로는 일어나지 않는다 (문자열/정수/bool 뿐)
	_ = enc.Encode(statusDoc{
		Status:    resp.Status,
		Message:   resp.Message,
		ExitCode:  exitCode,
		Truncated: resp.Truncated,
		Language:  "rust",
		Edition:   rustEdition,
		Rustc:     rustcVersion,
	})
	return buf.Bytes()
}
