package ipfs

import (
	"context"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type gotPart struct{ name, filename, ctype, data string }

// fakeKubo 는 add 요청의 쿼리와 multipart 파트를 기록하고 body 를 그대로 응답한다.
func fakeKubo(t *testing.T, status int, respBody string, parts *[]gotPart, query *string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v0/add" {
			t.Errorf("예상 밖 요청 %s %s", r.Method, r.URL.Path)
		}
		if query != nil {
			*query = r.URL.RawQuery
		}
		if parts != nil {
			_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil {
				t.Errorf("Content-Type: %v", err)
			} else {
				mr := multipart.NewReader(r.Body, params["boundary"])
				for {
					p, err := mr.NextPart()
					if err != nil {
						break
					}
					b, _ := io.ReadAll(p)
					*parts = append(*parts, gotPart{p.FormName(), p.FileName(), p.Header.Get("Content-Type"), string(b)})
				}
			}
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, respBody)
	}))
	t.Cleanup(srv.Close)
	return srv
}

var threeFiles = []File{{"main.rs", []byte("fn main(){}")}, {"output.txt", []byte("o")}, {"status.json", []byte("{}\n")}}

const okBody = `{"Name":"main.rs","Hash":"bafkreia","Size":"11"}
{"Name":"output.txt","Hash":"bafkreib","Size":"1"}
{"Name":"status.json","Hash":"bafkreic","Size":"3"}
{"Name":"","Hash":"bafybeidir","Size":"200"}
`

func TestAddDirRequestAndResponse(t *testing.T) {
	var parts []gotPart
	var q string
	srv := fakeKubo(t, 200, okBody, &parts, &q)
	cid, err := New(srv.URL).AddDir(context.Background(), threeFiles)
	if err != nil || cid != "bafybeidir" {
		t.Fatalf("cid=%q err=%v", cid, err)
	}
	for _, want := range []string{"wrap-with-directory=true", "cid-version=1", "raw-leaves=true", "pin=true"} {
		if !strings.Contains(q, want) {
			t.Errorf("쿼리에 %s 없음: %s", want, q)
		}
	}
	if len(parts) != 3 {
		t.Fatalf("파트 %d개", len(parts))
	}
	for i, f := range threeFiles {
		p := parts[i]
		if p.name != "file" || p.filename != f.Name || p.data != string(f.Data) || p.ctype != "application/octet-stream" {
			t.Errorf("파트 %d 이상: %+v", i, p)
		}
	}
}

func TestAddDirErrors(t *testing.T) {
	cases := map[string]struct {
		status int
		body   string
		want   string
	}{
		"HTTP 500":    {500, "datastore closed", "HTTP 500"},
		"디렉토리 엔트리 없음": {200, `{"Name":"main.rs","Hash":"x","Size":"1"}` + "\n", "엔트리"},
		"파일 엔트리 누락":   {200, `{"Name":"main.rs","Hash":"a","Size":"1"}` + "\n" + `{"Name":"","Hash":"d","Size":"1"}` + "\n", "output.txt"},
		"잘린 JSON":     {200, `{"Name":"main.rs","Hash":"a",`, "파싱"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			srv := fakeKubo(t, c.status, c.body, nil, nil)
			_, err := New(srv.URL).AddDir(context.Background(), threeFiles)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("err=%v (%q 포함 기대)", err, c.want)
			}
		})
	}
}

func TestAddDirContextTimeout(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() { close(release); srv.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	t0 := time.Now()
	_, err := New(srv.URL).AddDir(ctx, threeFiles)
	if err == nil || time.Since(t0) > 2*time.Second {
		t.Errorf("ctx timeout 에 끊겨야 함: err=%v 소요 %v", err, time.Since(t0))
	}
}

func TestAddDirRejectsUnsafeNames(t *testing.T) {
	srv := fakeKubo(t, 200, okBody, nil, nil)
	for _, n := range []string{"", "../x", `a"b`, "a/b", "a\nb"} {
		if _, err := New(srv.URL).AddDir(context.Background(), []File{{n, []byte("x")}}); err == nil {
			t.Errorf("파일 이름 %q 가 허용됨", n)
		}
	}
}

func TestAddDirConnectionRefused(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	if _, err := New(url).AddDir(context.Background(), threeFiles); err == nil {
		t.Error("연결 실패인데 error 없음")
	}
}
