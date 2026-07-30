package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func rawFileUploadRequest(t *testing.T, name string, idempotencyKey string, data []byte) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/file-uploads", bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set(fileUploadFilenameHeader, base64.RawURLEncoding.EncodeToString([]byte(name)))
	req.Header.Set(fileUploadIdempotencyHeader, idempotencyKey)
	req.Header.Set("Content-Type", "application/octet-stream")
	return req
}

func TestFileUploadRoundTripIsAuthenticatedAndIdempotent(t *testing.T) {
	cacheDir := t.TempDir()
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", cacheDir)
	server := newTestServer(t)
	content := []byte("# 发布计划\n\n支持移动端文件上传。\n")

	created := httptest.NewRecorder()
	server.handler.ServeHTTP(created, rawFileUploadRequest(t, "发布计划.md", "upload-test-key-1", content))
	if created.Code != http.StatusCreated {
		t.Fatalf("首次上传应创建文件，got=%d body=%s", created.Code, created.Body.String())
	}
	var metadata fileUploadResponse
	if err := json.NewDecoder(created.Body).Decode(&metadata); err != nil {
		t.Fatalf("响应不是合法 metadata：%v", err)
	}
	if !validFileUploadID(metadata.ID) || metadata.Name != "发布计划.md" ||
		metadata.ContentType != "text/plain; charset=utf-8" || metadata.Size != int64(len(content)) ||
		metadata.DownloadPath != "/api/file-uploads/"+metadata.ID {
		t.Fatalf("上传 metadata 不正确：%+v", metadata)
	}
	if strings.Contains(created.Body.String(), "idempotency_key") {
		t.Fatalf("响应不应泄露仅供服务端去重的幂等键：%s", created.Body.String())
	}
	if !metadata.ExpiresAt.After(metadata.CreatedAt) {
		t.Fatalf("上传文件必须有明确过期时间：%+v", metadata)
	}

	repeated := httptest.NewRecorder()
	server.handler.ServeHTTP(repeated, rawFileUploadRequest(t, "发布计划.md", "upload-test-key-1", content))
	if repeated.Code != http.StatusOK {
		t.Fatalf("相同幂等键和内容应返回已有上传，got=%d body=%s", repeated.Code, repeated.Body.String())
	}
	var repeatedMetadata fileUploadResponse
	if err := json.NewDecoder(repeated.Body).Decode(&repeatedMetadata); err != nil {
		t.Fatal(err)
	}
	if repeatedMetadata.ID != metadata.ID {
		t.Fatalf("幂等重试不应生成新 ID：first=%s repeated=%s", metadata.ID, repeatedMetadata.ID)
	}

	download := httptest.NewRecorder()
	server.handler.ServeHTTP(download, authedRequest(t, http.MethodGet, metadata.DownloadPath, nil))
	if download.Code != http.StatusOK || !bytes.Equal(download.Body.Bytes(), content) {
		t.Fatalf("下载内容不正确：code=%d body=%q", download.Code, download.Body.Bytes())
	}
	if download.Header().Get("ETag") != `"`+metadata.SHA256+`"` {
		t.Fatalf("下载应返回内容哈希 ETag：%v", download.Header())
	}

	unauthorizedDownload := httptest.NewRecorder()
	server.handler.ServeHTTP(
		unauthorizedDownload,
		httptest.NewRequest(http.MethodGet, metadata.DownloadPath, nil),
	)
	if unauthorizedDownload.Code != http.StatusUnauthorized {
		t.Fatalf("下载原文件同样必须要求 bearer：code=%d", unauthorizedDownload.Code)
	}

	conflict := httptest.NewRecorder()
	server.handler.ServeHTTP(conflict, rawFileUploadRequest(t, "发布计划.md", "upload-test-key-1", []byte("different")))
	if conflict.Code != http.StatusConflict {
		t.Fatalf("相同幂等键不能绑定不同内容，got=%d body=%s", conflict.Code, conflict.Body.String())
	}

	deleted := httptest.NewRecorder()
	server.handler.ServeHTTP(deleted, authedRequest(t, http.MethodDelete, metadata.DownloadPath, nil))
	if deleted.Code != http.StatusOK {
		t.Fatalf("删除上传应成功：code=%d body=%s", deleted.Code, deleted.Body.String())
	}
	missing := httptest.NewRecorder()
	server.handler.ServeHTTP(missing, authedRequest(t, http.MethodGet, metadata.DownloadPath, nil))
	if missing.Code != http.StatusNotFound {
		t.Fatalf("删除后下载必须返回 404：code=%d body=%s", missing.Code, missing.Body.String())
	}
}

func TestFileUploadExpiresAndUsesPrivateCachePermissions(t *testing.T) {
	cacheDir := filepath.Join(t.TempDir(), "uploads")
	store := newFileUploadStore(cacheDir)
	now := time.Date(2026, 7, 28, 8, 0, 0, 0, time.UTC)
	store.now = func() time.Time { return now }

	metadata, existing, err := store.put("notes.txt", "expiry-test-key", strings.NewReader("hello"))
	if err != nil || existing {
		t.Fatalf("创建上传失败：existing=%v err=%v", existing, err)
	}
	rootInfo, err := os.Stat(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && rootInfo.Mode().Perm() != 0o700 {
		t.Fatalf("缓存根目录权限必须是 0700：%o", rootInfo.Mode().Perm())
	}
	contentInfo, err := os.Stat(filepath.Join(cacheDir, metadata.ID, fileUploadContentFilename))
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && contentInfo.Mode().Perm() != 0o600 {
		t.Fatalf("缓存文件权限必须是 0600：%o", contentInfo.Mode().Perm())
	}

	now = now.Add(fileUploadTTL + time.Second)
	if _, _, err := store.read(metadata.ID); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("过期上传应不可读取：%v", err)
	}
	if _, err := os.Stat(filepath.Join(cacheDir, metadata.ID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("读取过期上传时应同步清理缓存目录：%v", err)
	}
}

func TestFileUploadRejectsUnsupportedOrSpoofedContent(t *testing.T) {
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", t.TempDir())
	server := newTestServer(t)

	tests := []struct {
		name string
		data []byte
	}{
		{name: "binary.exe", data: []byte("MZ binary")},
		{name: "spoofed.pdf", data: []byte("not a pdf")},
		{name: "binary.txt", data: []byte{'a', 0, 'b'}},
	}
	for index, item := range tests {
		t.Run(item.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			server.handler.ServeHTTP(rec, rawFileUploadRequest(
				t,
				item.name,
				"unsupported-test-key-"+string(rune('a'+index)),
				item.data,
			))
			if rec.Code != http.StatusUnsupportedMediaType {
				t.Fatalf("伪装或不支持的文件应返回 415：code=%d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestFileUploadRejectsOversizeAndCleansPartialFile(t *testing.T) {
	cacheDir := t.TempDir()
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", cacheDir)
	server := newTestServer(t)
	data := bytes.Repeat([]byte("a"), int(fileUploadRequestBodyMaxBytes)+1)
	req := rawFileUploadRequest(t, "large.txt", "oversize-test-key", data)
	req.ContentLength = -1
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超限流式上传应返回 413：code=%d body=%s", rec.Code, rec.Body.String())
	}
	entries, err := os.ReadDir(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), fileUploadPartialPrefix) {
			t.Fatalf("失败上传不应残留 partial：%s", filepath.Join(cacheDir, entry.Name()))
		}
	}
}

func TestFileUploadRequiresBearerToken(t *testing.T) {
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", t.TempDir())
	server := newTestServer(t)
	req := rawFileUploadRequest(t, "notes.txt", "auth-test-key", []byte("hello"))
	req.Header.Del("Authorization")
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("文件上传必须要求 bearer：code=%d body=%s", rec.Code, rec.Body.String())
	}
}
