package execute

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"

	"lgtm/backend/internal/ipfs"
	"lgtm/backend/internal/wasmexec"
)

// fakeUploader 는 받은 파일을 기록하고 입력 해시로 결정론적인 가짜 CID 를 돌려준다. err 가 있으면 실패, block 이면 ctx 가 끝날 때까지 대기한다.
type fakeUploader struct {
	mu    sync.Mutex
	calls [][]ipfs.File
	err   error
	block bool
}

func (f *fakeUploader) AddDir(ctx context.Context, files []ipfs.File) (string, error) {
	f.mu.Lock()
	f.calls = append(f.calls, files)
	f.mu.Unlock()
	if f.block {
		<-ctx.Done()
		return "", ctx.Err()
	}
	if f.err != nil {
		return "", f.err
	}
	h := sha256.New()
	for _, x := range files {
		h.Write([]byte(x.Name))
		h.Write(x.Data)
	}
	return "bafytest" + hex.EncodeToString(h.Sum(nil))[:20], nil
}

func (f *fakeUploader) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func fileMap(files []ipfs.File) map[string]string {
	m := map[string]string{}
	for _, f := range files {
		m[f.Name] = string(f.Data)
	}
	return m
}

func TestBuildFilesFormat(t *testing.T) {
	zero, three := 0, 3
	cases := []struct {
		name       string
		resp       response
		exit       *int
		wantOutput string
		wantStatus string
	}{
		{"success", response{Status: "success", Stdout: "hi\n", Stderr: "warn"}, &zero,
			"--- stdout ---\nhi\n--- stderr ---\nwarn\n",
			"{\n  \"status\": \"success\",\n  \"message\": \"\",\n  \"exit_code\": 0,\n  \"truncated\": false,\n  \"language\": \"rust\",\n  \"edition\": \"2021\",\n  \"rustc\": \"" + rustcVersion + "\"\n}\n"},
		{"compile_error 는 exit_code null, rustc 메시지는 stderr", response{Status: "compile_error", Message: "error: <x> & y", Stderr: "error: boom\n"}, nil,
			"--- stdout ---\n--- stderr ---\nerror: boom\n",
			"{\n  \"status\": \"compile_error\",\n  \"message\": \"error: <x> & y\",\n  \"exit_code\": null,\n  \"truncated\": false,\n  \"language\": \"rust\",\n  \"edition\": \"2021\",\n  \"rustc\": \"" + rustcVersion + "\"\n}\n"},
		{"truncated 표시", response{Status: "runtime_error", Message: "exit code 3", Stdout: "x", Truncated: true}, &three,
			"--- stdout ---\nx\n--- stderr ---\n--- truncated: output exceeded 10240 bytes ---\n",
			"{\n  \"status\": \"runtime_error\",\n  \"message\": \"exit code 3\",\n  \"exit_code\": 3,\n  \"truncated\": true,\n  \"language\": \"rust\",\n  \"edition\": \"2021\",\n  \"rustc\": \"" + rustcVersion + "\"\n}\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			files := buildFiles("fn main() {}", c.resp, c.exit)
			if len(files) != 3 || files[0].Name != "main.rs" || files[1].Name != "output.txt" || files[2].Name != "status.json" {
				t.Fatalf("파일 구성 이상: %v", files)
			}
			m := fileMap(files)
			if m["main.rs"] != "fn main() {}" {
				t.Errorf("main.rs 는 원문 그대로여야 함: %q", m["main.rs"])
			}
			if m["output.txt"] != c.wantOutput {
				t.Errorf("output.txt=%q 기대 %q", m["output.txt"], c.wantOutput)
			}
			if m["status.json"] != c.wantStatus {
				t.Errorf("status.json=%q 기대 %q", m["status.json"], c.wantStatus)
			}
			// 결정론: 같은 입력 → 바이트 동일
			again := buildFiles("fn main() {}", c.resp, c.exit)
			for i := range files {
				if !bytes.Equal(files[i].Data, again[i].Data) {
					t.Errorf("%s 가 호출마다 다름", files[i].Name)
				}
			}
		})
	}
}

// 요청마다 달라지는 값(trace_id, timings)이 응답에 있어도 업로드 내용에는 들어가지 않는다.
func TestBuildFilesIgnoresPerRequestFields(t *testing.T) {
	a := response{Status: "success", Stdout: "o", TraceID: "aaaa", TimingsMS: timings{Compile: 1, Execute: 2, IPFSUpload: 3}}
	b := response{Status: "success", Stdout: "o", TraceID: "bbbb", TimingsMS: timings{Compile: 90, Execute: 80, IPFSUpload: 70}}
	zero := 0
	fa, fb := buildFiles("c", a, &zero), buildFiles("c", b, &zero)
	for i := range fa {
		if !bytes.Equal(fa[i].Data, fb[i].Data) {
			t.Errorf("%s 가 trace_id/timings 에 영향받음", fa[i].Name)
		}
	}
}

func TestUploadOnEveryStatus(t *testing.T) {
	cases := []struct {
		name string
		exec *fakeExec
		code string
		want string
	}{
		{"success", okExec(), `fn main() {}`, "success"},
		{"compile_error", okExec(), syntaxErr, "compile_error"},
		{"runtime_error", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusRuntimeError, Message: "exit 3", ExitCode: 3}}, `fn main() {}`, "runtime_error"},
		{"timeout", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusTimeout, Message: "t", ExitCode: -1}}, `fn main() {}`, "timeout"},
		{"memory_limit", &fakeExec{res: wasmexec.Result{Status: wasmexec.StatusMemoryLimit, Message: "m", ExitCode: -1}}, `fn main() {}`, "memory_limit"},
		{"internal_error", &fakeExec{err: errors.New("boom")}, `fn main() {}`, "internal_error"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			up := &fakeUploader{}
			srv, _, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, c.exec, up)
			resp, m := post(t, srv.URL, codeBody(c.code))
			if resp.StatusCode != 200 || m["status"] != c.want {
				t.Fatalf("응답 이상: %d %v", resp.StatusCode, m)
			}
			if up.count() != 1 {
				t.Fatalf("업로드 %d회 (1회 기대)", up.count())
			}
			cid, _ := m["cid"].(string)
			url, _ := m["ipfs_url"].(string)
			if cid == "" || url != "http://ipfs.lgtm.local/ipfs/"+cid+"/" {
				t.Errorf("cid/ipfs_url 이상: %q %q", cid, url)
			}
			st := fileMap(up.calls[0])["status.json"]
			if !strings.Contains(st, `"status": "`+c.want+`"`) {
				t.Errorf("status.json 에 status 불일치: %s", st)
			}
			if c.want == "compile_error" || c.want == "internal_error" {
				if !strings.Contains(st, `"exit_code": null`) {
					t.Errorf("%s 는 exit_code null 이어야 함: %s", c.want, st)
				}
			}
		})
	}
}

func TestNoUploadFor400And413(t *testing.T) {
	up := &fakeUploader{}
	srv, _, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, okExec(), up)
	if resp, _ := post(t, srv.URL, `{"language":"go","code":"x"}`); resp.StatusCode != 400 {
		t.Fatalf("400 기대: %d", resp.StatusCode)
	}
	if resp, _ := post(t, srv.URL, codeBody(strings.Repeat("a", maxBodyBytes+10))); resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("413 기대: %d", resp.StatusCode)
	}
	if up.count() != 0 {
		t.Errorf("400/413 은 업로드하지 않아야 함: %d회", up.count())
	}
}

func TestSameResultSameFiles(t *testing.T) {
	up := &fakeUploader{}
	srv, _, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, okExec(), up)
	_, m1 := post(t, srv.URL, codeBody(`fn main() {}`))
	_, m2 := post(t, srv.URL, codeBody(`fn main() {}`))
	if m1["cid"] != m2["cid"] || up.count() != 2 {
		t.Fatalf("같은 입력인데 CID 다름: %v %v", m1["cid"], m2["cid"])
	}
	for i := range up.calls[0] {
		if !bytes.Equal(up.calls[0][i].Data, up.calls[1][i].Data) {
			t.Errorf("%s 가 요청마다 다름 (CID 결정론 위반)", up.calls[0][i].Name)
		}
	}
}

func TestUploadSpansAndAttributes(t *testing.T) {
	up := &fakeUploader{}
	srv, rec, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, okExec(), up)
	_, m := post(t, srv.URL, codeBody(`fn main() {}`))
	cid := m["cid"].(string)
	spans := map[string]sdktrace.ReadOnlySpan{}
	for _, s := range rec.Ended() {
		spans[s.Name()] = s
	}
	attr := func(s sdktrace.ReadOnlySpan, k string) string {
		for _, a := range s.Attributes() {
			if string(a.Key) == k {
				return a.Value.AsString()
			}
		}
		return ""
	}
	if attr(spans["ipfs.upload"], "ipfs.cid") != cid || attr(spans["POST /api/execute"], "ipfs.cid") != cid {
		t.Errorf("ipfs.cid attribute 불일치: upload=%q root=%q cid=%q", attr(spans["ipfs.upload"], "ipfs.cid"), attr(spans["POST /api/execute"], "ipfs.cid"), cid)
	}
	if spans["ipfs.upload"].Status().Code.String() == "Error" {
		t.Error("성공한 업로드 span 이 ERROR")
	}
}

// 업로드 실패는 부분 실패: 응답 status 와 root span 은 그대로, ipfs.upload span 만 ERROR, cid/ipfs_url null.
func TestUploadFailureIsPartial(t *testing.T) {
	cases := map[string]*fakeUploader{
		"kubo 오류": {err: errors.New("kubo add HTTP 500")},
	}
	for name, up := range cases {
		t.Run(name, func(t *testing.T) {
			srv, rec, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, okExec(), up)
			resp, m := post(t, srv.URL, codeBody(`fn main() {}`))
			assertPartial(t, resp.StatusCode, m, rec)
		})
	}
}

func assertPartial(t *testing.T, code int, m map[string]any, rec interface {
	Ended() []sdktrace.ReadOnlySpan
}) {
	t.Helper()
	if code != 200 || m["status"] != "success" || m["stdout"] != "stub output\n" {
		t.Fatalf("실행 결과가 바뀜: %d %v", code, m)
	}
	if v, ok := m["cid"]; !ok || v != nil {
		t.Errorf("cid 는 null 이어야 함: %v (present=%v)", v, ok)
	}
	if v, ok := m["ipfs_url"]; !ok || v != nil {
		t.Errorf("ipfs_url 은 null 이어야 함: %v (present=%v)", v, ok)
	}
	spans := map[string]sdktrace.ReadOnlySpan{}
	for _, s := range rec.Ended() {
		spans[s.Name()] = s
	}
	if spans["ipfs.upload"].Status().Code.String() != "Error" {
		t.Errorf("ipfs.upload span 은 ERROR 여야 함: %v", spans["ipfs.upload"].Status().Code)
	}
	if spans["POST /api/execute"].Status().Code.String() == "Error" {
		t.Error("업로드 실패로 root span 이 ERROR 가 되면 안 됨 (부분 실패)")
	}
	for _, a := range spans["POST /api/execute"].Attributes() {
		if a.Key == attribute.Key("ipfs.cid") {
			t.Error("업로드 실패인데 root 에 ipfs.cid 있음")
		}
	}
}

// Kubo 가 응답하지 않으면(ctx 가 끝날 때까지 안 돌아옴) timeout 에서 끊고 부분 실패로 응답한다. timeout 값은 테스트에서만 짧게 바꾼다.
func TestUploadTimeoutIsPartial(t *testing.T) {
	old := ipfsUploadTimeout
	ipfsUploadTimeout = 200 * time.Millisecond
	t.Cleanup(func() { ipfsUploadTimeout = old })
	up := &fakeUploader{block: true}
	srv, rec, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, okExec(), up)
	t0 := time.Now()
	resp, m := post(t, srv.URL, codeBody(`fn main() {}`))
	if d := time.Since(t0); d > 3*time.Second {
		t.Errorf("timeout 후 응답이 %v 걸림", d)
	}
	assertPartial(t, resp.StatusCode, m, rec)
}

// 10초 timeout: ctx 가 끝날 때까지 안 돌아오는 Kubo. 테스트 시간을 위해 ipfsUploadTimeout 값 자체를 검사하고, 호출 ctx 에 deadline 이 있는지 확인한다.
func TestUploadContextHasTenSecondDeadline(t *testing.T) {
	if ipfsUploadTimeout != 10*time.Second {
		t.Fatalf("ipfsUploadTimeout=%v (PRD BE-10: 10초)", ipfsUploadTimeout)
	}
	var got time.Duration
	up := &deadlineUploader{out: &got}
	srv, _, _ := newServerWithUploader(t, newFakeCompiler(t, nil).srv.URL, okExec(), up)
	post(t, srv.URL, codeBody(`fn main() {}`))
	if got < 9*time.Second || got > 10*time.Second {
		t.Errorf("업로드 ctx deadline 까지 %v (10초 이내·근처 기대)", got)
	}
}

type deadlineUploader struct{ out *time.Duration }

func (d *deadlineUploader) AddDir(ctx context.Context, _ []ipfs.File) (string, error) {
	if dl, ok := ctx.Deadline(); ok {
		*d.out = time.Until(dl)
	}
	return "bafydeadline", nil
}
