// Package ipfs는 Kubo HTTP API(5001, 클러스터 내부 Service)로 디렉토리를 올린다 (F-M3-02).
package ipfs

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"strings"
)

// maxResponseBytes는 add 응답(파일마다 한 줄 JSON)을 읽는 상한이다.
const maxResponseBytes = 1 << 20

// File은 업로드할 파일 하나다. Name은 서비스 코드가 정한 고정 이름이어야 한다 (사용자 입력 금지).
type File struct {
	Name string
	Data []byte
}

// Client는 Kubo API 클라이언트다. timeout은 호출하는 쪽이 ctx로 건다.
type Client struct {
	baseURL string
	http    *http.Client
}

// New는 baseURL(예: http://kubo-api.ipfs.svc.cluster.local:5001)을 가리키는 Client를 만든다.
//
// keep-alive를 끈다: 업로드는 드물고 클러스터 안이라 연결 비용이 작다. keep-alive가 켜져 있을 때는 Kubo 5001을 NetworkPolicy로
// 막은 뒤에도 업로드가 성공했다(F-M3-02 검증에서 관측. 기존 연결 재사용 때문으로 추정). 끄면 차단이 곧바로 실패로 나타난다.
func New(baseURL string) *Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DisableKeepAlives = true
	return &Client{baseURL: strings.TrimRight(baseURL, "/"), http: &http.Client{Transport: tr}}
}

// addEntry는 /api/v0/add 응답의 한 줄이다. Name이 비어 있는 엔트리가 wrap-with-directory의 디렉토리다.
type addEntry struct {
	Name string `json:"Name"`
	Hash string `json:"Hash"`
}

// AddDir은 files를 wrap-with-directory로 묶어 CIDv1(raw-leaves)로 add + pin하고 디렉토리 CID를 돌려준다.
// CID 설정을 Kubo의 Import.* 기본값에 맡기지 않도록 옵션을 명시한다. mtime/mode는 저장하지 않으므로 같은 입력은 같은 CID다.
func (c *Client) AddDir(ctx context.Context, files []File) (string, error) {
	if len(files) == 0 {
		return "", errors.New("업로드할 파일 없음")
	}
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	for _, f := range files {
		if f.Name == "" || strings.ContainsAny(f.Name, "\"\\/\r\n") {
			return "", fmt.Errorf("허용되지 않는 파일 이름 %q", f.Name)
		}
		h := textproto.MIMEHeader{}
		h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename="%s"`, f.Name))
		h.Set("Content-Type", "application/octet-stream")
		part, err := mw.CreatePart(h)
		if err != nil {
			return "", err
		}
		if _, err := part.Write(f.Data); err != nil {
			return "", err
		}
	}
	if err := mw.Close(); err != nil {
		return "", err
	}

	q := url.Values{}
	q.Set("wrap-with-directory", "true")
	q.Set("cid-version", "1")
	q.Set("raw-leaves", "true")
	q.Set("pin", "true")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/v0/add?"+q.Encode(), &body)
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("kubo add 요청 실패: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return "", fmt.Errorf("kubo add HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	// 응답은 줄 단위 JSON이다 (파일마다 한 줄, 마지막이 디렉토리). 중간에 실패하면 trailer X-Stream-Error 로 알려 준다.
	dec := json.NewDecoder(io.LimitReader(resp.Body, maxResponseBytes))
	seen := map[string]bool{}
	var dirCID string
	for {
		var e addEntry
		if err := dec.Decode(&e); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return "", fmt.Errorf("kubo add 응답 파싱 실패: %w", err)
		}
		if e.Hash == "" {
			continue
		}
		if e.Name == "" {
			dirCID = e.Hash
		} else {
			seen[e.Name] = true
		}
	}
	if msg := resp.Trailer.Get("X-Stream-Error"); msg != "" {
		return "", fmt.Errorf("kubo add 스트림 오류: %s", msg)
	}
	for _, f := range files {
		if !seen[f.Name] {
			return "", fmt.Errorf("kubo add 응답에 %s 엔트리 없음", f.Name)
		}
	}
	if dirCID == "" {
		return "", errors.New("kubo add 응답에 디렉토리 CID 없음")
	}
	return dirCID, nil
}
