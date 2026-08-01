package httpapi

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const (
	fileUploadFilenameHeader           = "X-Mimi-File-Name"
	fileUploadIdempotencyHeader        = "Idempotency-Key"
	fileUploadDownloadPathPrefix       = "/api/file-uploads/"
	fileUploadMetadataFilename         = "metadata.json"
	fileUploadContentFilename          = "content"
	fileUploadPartialPrefix            = ".partial-"
	fileUploadIDBytes                  = 16
	fileUploadMaxFilenameBytes         = 255
	fileUploadSampleBytes              = 8 << 10
	fileUploadMaxEntries               = 128
	fileUploadPartialMaxAge            = time.Hour
	fileUploadTTL                      = 7 * 24 * time.Hour
	fileUploadStoreMaxBytes      int64 = 512 << 20
)

var fileUploadTextExtensions = map[string]struct{}{
	".c":        {},
	".cc":       {},
	".cpp":      {},
	".css":      {},
	".csv":      {},
	".go":       {},
	".h":        {},
	".hpp":      {},
	".html":     {},
	".java":     {},
	".js":       {},
	".json":     {},
	".jsx":      {},
	".kt":       {},
	".kts":      {},
	".md":       {},
	".markdown": {},
	".php":      {},
	".py":       {},
	".rb":       {},
	".rs":       {},
	".sh":       {},
	".sql":      {},
	".swift":    {},
	".toml":     {},
	".ts":       {},
	".tsx":      {},
	".txt":      {},
	".xml":      {},
	".yaml":     {},
	".yml":      {},
	".zsh":      {},
}

type fileUploadStore struct {
	root string
	now  func() time.Time
	mu   sync.Mutex
}

type fileUploadMetadata struct {
	ID             string    `json:"upload_id"`
	IdempotencyKey string    `json:"idempotency_key"`
	Name           string    `json:"name"`
	ContentType    string    `json:"content_type"`
	Size           int64     `json:"size"`
	SHA256         string    `json:"sha256"`
	CreatedAt      time.Time `json:"created_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	DownloadPath   string    `json:"download_path"`
}

// fileUploadResponse 只暴露客户端继续处理附件所需字段。
// Idempotency-Key 仅保存在 Mac 本地用于重试去重，不回传给移动端或日志链路。
type fileUploadResponse struct {
	ID           string    `json:"upload_id"`
	Name         string    `json:"name"`
	ContentType  string    `json:"content_type"`
	Size         int64     `json:"size"`
	SHA256       string    `json:"sha256"`
	CreatedAt    time.Time `json:"created_at"`
	ExpiresAt    time.Time `json:"expires_at"`
	DownloadPath string    `json:"download_path"`
}

func (m fileUploadMetadata) response() fileUploadResponse {
	return fileUploadResponse{
		ID:           m.ID,
		Name:         m.Name,
		ContentType:  m.ContentType,
		Size:         m.Size,
		SHA256:       m.SHA256,
		CreatedAt:    m.CreatedAt,
		ExpiresAt:    m.ExpiresAt,
		DownloadPath: m.DownloadPath,
	}
}

type stagedFileUpload struct {
	partialDir string
	content    string
	size       int64
	sha256     string
}

func newFileUploadStore(root string) *fileUploadStore {
	return &fileUploadStore{
		root: strings.TrimSpace(root),
		now:  time.Now,
	}
}

func (s *fileUploadStore) probe() error {
	if s == nil || s.root == "" {
		return errors.New("文件上传缓存目录为空")
	}
	if err := os.MkdirAll(s.root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(s.root, 0o700); err != nil {
		return err
	}
	probe, err := os.CreateTemp(s.root, ".capability-probe-")
	if err != nil {
		return err
	}
	probePath := probe.Name()
	defer os.Remove(probePath)
	if err := probe.Chmod(0o600); err != nil {
		_ = probe.Close()
		return err
	}
	return probe.Close()
}

func defaultFileUploadRoot() string {
	if override := strings.TrimSpace(os.Getenv("AGENTD_FILE_UPLOAD_CACHE_DIR")); override != "" {
		return override
	}
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return filepath.Join(os.TempDir(), config.AppName, "file-uploads")
	}
	return filepath.Join(cacheDir, config.AppName, "file-uploads")
}

func (r *Router) fileUploadHandler(w http.ResponseWriter, req *http.Request) {
	if !r.capabilities.enabled(fileUploadCapability) {
		r.capabilities.writeUnavailable(w, fileUploadCapability)
		return
	}
	if req.URL.Path == "/api/file-uploads" {
		if req.Method != http.MethodPost {
			methodNotAllowed(w)
			return
		}
		r.createFileUpload(w, req)
		return
	}

	id := strings.TrimPrefix(req.URL.Path, fileUploadDownloadPathPrefix)
	if !validFileUploadID(id) || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "文件不存在或已过期")
		return
	}
	switch req.Method {
	case http.MethodGet:
		r.downloadFileUpload(w, id)
	case http.MethodDelete:
		r.deleteFileUpload(w, id)
	default:
		methodNotAllowed(w)
	}
}

func (r *Router) createFileUpload(w http.ResponseWriter, req *http.Request) {
	if r.fileUploads == nil {
		writeError(w, http.StatusServiceUnavailable, "文件上传服务暂不可用")
		return
	}

	name, err := decodeFileUploadName(req.Header.Get(fileUploadFilenameHeader))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	idempotencyKey := strings.TrimSpace(req.Header.Get(fileUploadIdempotencyHeader))
	if !validFileUploadIdempotencyKey(idempotencyKey) {
		writeError(w, http.StatusBadRequest, "Idempotency-Key 必须是 8 至 128 位可打印 ASCII 字符")
		return
	}

	metadata, existing, err := r.fileUploads.put(name, idempotencyKey, req.Body)
	if err != nil {
		var maxBytesError *http.MaxBytesError
		switch {
		case errors.As(err, &maxBytesError):
			writeError(w, http.StatusRequestEntityTooLarge, "文件不能超过 20 MiB")
		case errors.Is(err, errFileUploadConflict):
			writeError(w, http.StatusConflict, "相同 Idempotency-Key 已用于其他文件")
		case errors.Is(err, errUnsupportedFileUpload):
			writeError(w, http.StatusUnsupportedMediaType, err.Error())
		default:
			writeError(w, http.StatusInternalServerError, "保存上传文件失败")
		}
		return
	}
	status := http.StatusCreated
	if existing {
		status = http.StatusOK
	}
	writeJSON(w, status, metadata.response())
}

func (r *Router) downloadFileUpload(w http.ResponseWriter, id string) {
	if r.fileUploads == nil {
		writeError(w, http.StatusNotFound, "文件不存在或已过期")
		return
	}
	metadata, data, err := r.fileUploads.read(id)
	if err != nil {
		writeError(w, http.StatusNotFound, "文件不存在或已过期")
		return
	}

	w.Header().Set("Content-Type", metadata.ContentType)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", metadata.Size))
	w.Header().Set("ETag", `"`+metadata.SHA256+`"`)
	w.Header().Set("Content-Disposition", `attachment; filename="file"; filename*=UTF-8''`+percentEncodeRFC5987(metadata.Name))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (r *Router) deleteFileUpload(w http.ResponseWriter, id string) {
	if r.fileUploads == nil || r.fileUploads.delete(id) != nil {
		writeError(w, http.StatusNotFound, "文件不存在或已过期")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

var (
	errUnsupportedFileUpload = errors.New("不支持该文件类型")
	errFileUploadConflict    = errors.New("idempotency key conflict")
)

func (s *fileUploadStore) put(name string, idempotencyKey string, body io.Reader) (fileUploadMetadata, bool, error) {
	staged, err := s.stage(body)
	if err != nil {
		return fileUploadMetadata{}, false, err
	}
	defer os.RemoveAll(staged.partialDir)

	contentType, err := validateUploadedFile(name, staged.content)
	if err != nil {
		return fileUploadMetadata{}, false, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now().UTC()
	if err := s.ensureRootLocked(); err != nil {
		return fileUploadMetadata{}, false, err
	}
	s.pruneLocked(now)

	if existing, ok := s.findByIdempotencyKeyLocked(idempotencyKey); ok {
		if existing.SHA256 != staged.sha256 {
			return fileUploadMetadata{}, false, errFileUploadConflict
		}
		return existing, true, nil
	}

	id, err := randomFileUploadID()
	if err != nil {
		return fileUploadMetadata{}, false, err
	}
	createdAt := now
	metadata := fileUploadMetadata{
		ID:             id,
		IdempotencyKey: idempotencyKey,
		Name:           name,
		ContentType:    contentType,
		Size:           staged.size,
		SHA256:         staged.sha256,
		CreatedAt:      createdAt,
		ExpiresAt:      createdAt.Add(fileUploadTTL),
		DownloadPath:   fileUploadDownloadPathPrefix + id,
	}
	if err := writeFileUploadMetadata(staged.partialDir, metadata); err != nil {
		return fileUploadMetadata{}, false, err
	}
	finalDir := filepath.Join(s.root, id)
	if err := os.Rename(staged.partialDir, finalDir); err != nil {
		return fileUploadMetadata{}, false, err
	}
	s.enforceLimitsLocked(now)
	return metadata, false, nil
}

func (s *fileUploadStore) stage(body io.Reader) (stagedFileUpload, error) {
	if err := os.MkdirAll(s.root, 0o700); err != nil {
		return stagedFileUpload{}, err
	}
	if err := os.Chmod(s.root, 0o700); err != nil {
		return stagedFileUpload{}, err
	}
	id, err := randomFileUploadID()
	if err != nil {
		return stagedFileUpload{}, err
	}
	partialDir := filepath.Join(s.root, fileUploadPartialPrefix+id)
	if err := os.Mkdir(partialDir, 0o700); err != nil {
		return stagedFileUpload{}, err
	}
	contentPath := filepath.Join(partialDir, fileUploadContentFilename)
	file, err := os.OpenFile(contentPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		_ = os.RemoveAll(partialDir)
		return stagedFileUpload{}, err
	}
	hasher := sha256.New()
	size, copyErr := io.Copy(io.MultiWriter(file, hasher), body)
	closeErr := file.Close()
	if copyErr != nil {
		_ = os.RemoveAll(partialDir)
		return stagedFileUpload{}, copyErr
	}
	if closeErr != nil {
		_ = os.RemoveAll(partialDir)
		return stagedFileUpload{}, closeErr
	}
	if size == 0 {
		_ = os.RemoveAll(partialDir)
		return stagedFileUpload{}, fmt.Errorf("%w：文件不能为空", errUnsupportedFileUpload)
	}
	return stagedFileUpload{
		partialDir: partialDir,
		content:    contentPath,
		size:       size,
		sha256:     hex.EncodeToString(hasher.Sum(nil)),
	}, nil
}

func (s *fileUploadStore) read(id string) (fileUploadMetadata, []byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now().UTC()
	if err := s.ensureRootLocked(); err != nil {
		return fileUploadMetadata{}, nil, err
	}
	s.pruneLocked(now)
	metadata, err := readFileUploadMetadata(filepath.Join(s.root, id))
	if err != nil || !metadata.ExpiresAt.After(now) {
		return fileUploadMetadata{}, nil, os.ErrNotExist
	}
	data, err := os.ReadFile(filepath.Join(s.root, id, fileUploadContentFilename))
	if err != nil {
		return fileUploadMetadata{}, nil, err
	}
	if int64(len(data)) != metadata.Size {
		return fileUploadMetadata{}, nil, errors.New("file upload size mismatch")
	}
	return metadata, data, nil
}

func (s *fileUploadStore) delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !validFileUploadID(id) {
		return os.ErrNotExist
	}
	target := filepath.Join(s.root, id)
	if _, err := os.Lstat(target); err != nil {
		return os.ErrNotExist
	}
	return os.RemoveAll(target)
}

func (s *fileUploadStore) ensureRootLocked() error {
	if err := os.MkdirAll(s.root, 0o700); err != nil {
		return err
	}
	return os.Chmod(s.root, 0o700)
}

func (s *fileUploadStore) pruneLocked(now time.Time) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return
	}
	for _, entry := range entries {
		path := filepath.Join(s.root, entry.Name())
		if strings.HasPrefix(entry.Name(), fileUploadPartialPrefix) {
			if info, err := entry.Info(); err == nil && now.Sub(info.ModTime()) > fileUploadPartialMaxAge {
				_ = os.RemoveAll(path)
			}
			continue
		}
		if !entry.IsDir() || !validFileUploadID(entry.Name()) {
			continue
		}
		metadata, err := readFileUploadMetadata(path)
		if err != nil || !metadata.ExpiresAt.After(now) {
			_ = os.RemoveAll(path)
		}
	}
}

func (s *fileUploadStore) enforceLimitsLocked(now time.Time) {
	type item struct {
		id        string
		size      int64
		createdAt time.Time
	}
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return
	}
	items := make([]item, 0, len(entries))
	var total int64
	for _, entry := range entries {
		if !entry.IsDir() || !validFileUploadID(entry.Name()) {
			continue
		}
		metadata, err := readFileUploadMetadata(filepath.Join(s.root, entry.Name()))
		if err != nil || !metadata.ExpiresAt.After(now) {
			continue
		}
		items = append(items, item{id: entry.Name(), size: metadata.Size, createdAt: metadata.CreatedAt})
		total += metadata.Size
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].createdAt.Before(items[j].createdAt)
	})
	for len(items) > fileUploadMaxEntries || total > fileUploadStoreMaxBytes {
		oldest := items[0]
		items = items[1:]
		_ = os.RemoveAll(filepath.Join(s.root, oldest.id))
		total -= oldest.size
	}
}

func (s *fileUploadStore) findByIdempotencyKeyLocked(key string) (fileUploadMetadata, bool) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return fileUploadMetadata{}, false
	}
	for _, entry := range entries {
		if !entry.IsDir() || !validFileUploadID(entry.Name()) {
			continue
		}
		metadata, err := readFileUploadMetadata(filepath.Join(s.root, entry.Name()))
		if err == nil && metadata.IdempotencyKey == key {
			return metadata, true
		}
	}
	return fileUploadMetadata{}, false
}

func writeFileUploadMetadata(dir string, metadata fileUploadMetadata) error {
	path := filepath.Join(dir, fileUploadMetadataFilename)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(file)
	encoder.SetEscapeHTML(false)
	encodeErr := encoder.Encode(metadata)
	closeErr := file.Close()
	if encodeErr != nil {
		return encodeErr
	}
	return closeErr
}

func readFileUploadMetadata(dir string) (fileUploadMetadata, error) {
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fileUploadMetadata{}, os.ErrNotExist
	}
	data, err := os.ReadFile(filepath.Join(dir, fileUploadMetadataFilename))
	if err != nil {
		return fileUploadMetadata{}, err
	}
	var metadata fileUploadMetadata
	if err := json.Unmarshal(data, &metadata); err != nil {
		return fileUploadMetadata{}, err
	}
	if !validFileUploadID(metadata.ID) || metadata.Name == "" || metadata.Size <= 0 || metadata.SHA256 == "" {
		return fileUploadMetadata{}, errors.New("invalid file upload metadata")
	}
	if filepath.Base(dir) != metadata.ID {
		return fileUploadMetadata{}, errors.New("file upload directory mismatch")
	}
	return metadata, nil
}

func validateUploadedFile(name string, path string) (string, error) {
	extension := strings.ToLower(filepath.Ext(name))
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	sample := make([]byte, fileUploadSampleBytes)
	n, readErr := io.ReadFull(file, sample)
	if readErr != nil && readErr != io.EOF && readErr != io.ErrUnexpectedEOF {
		return "", readErr
	}
	sample = sample[:n]

	if extension == ".pdf" {
		if len(sample) < 5 || string(sample[:5]) != "%PDF-" {
			return "", fmt.Errorf("%w：PDF 文件头无效", errUnsupportedFileUpload)
		}
		return "application/pdf", nil
	}
	if _, ok := fileUploadTextExtensions[extension]; !ok {
		return "", fmt.Errorf("%w：仅支持 PDF、文本和常见源码文件", errUnsupportedFileUpload)
	}
	if strings.IndexByte(string(sample), 0) >= 0 || !utf8.Valid(sample) {
		return "", fmt.Errorf("%w：文本文件包含二进制内容或不是 UTF-8", errUnsupportedFileUpload)
	}
	switch extension {
	case ".json":
		return "application/json", nil
	case ".csv":
		return "text/csv", nil
	case ".html":
		return "text/html", nil
	case ".css":
		return "text/css", nil
	case ".xml":
		return "application/xml", nil
	default:
		return "text/plain; charset=utf-8", nil
	}
}

func decodeFileUploadName(encoded string) (string, error) {
	encoded = strings.TrimSpace(encoded)
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(data) == 0 || len(data) > fileUploadMaxFilenameBytes || !utf8.Valid(data) {
		return "", errors.New("X-Mimi-File-Name 必须是有效的 base64url UTF-8 文件名")
	}
	name := strings.TrimSpace(string(data))
	if name == "" || name == "." || name == ".." || filepath.Base(name) != name ||
		strings.ContainsAny(name, `/\`) {
		return "", errors.New("文件名不合法")
	}
	for _, value := range name {
		if value < 0x20 || value == 0x7f {
			return "", errors.New("文件名不能包含控制字符")
		}
	}
	return name, nil
}

func validFileUploadIdempotencyKey(value string) bool {
	if len(value) < 8 || len(value) > 128 {
		return false
	}
	for _, item := range value {
		if item < 0x21 || item > 0x7e {
			return false
		}
	}
	return true
}

func randomFileUploadID() (string, error) {
	data := make([]byte, fileUploadIDBytes)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

func validFileUploadID(value string) bool {
	if len(value) != fileUploadIDBytes*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func percentEncodeRFC5987(value string) string {
	const hexChars = "0123456789ABCDEF"
	var builder strings.Builder
	for _, item := range []byte(value) {
		if (item >= 'a' && item <= 'z') || (item >= 'A' && item <= 'Z') ||
			(item >= '0' && item <= '9') || strings.ContainsRune("!#$&+-.^_`|~", rune(item)) {
			builder.WriteByte(item)
			continue
		}
		builder.WriteByte('%')
		builder.WriteByte(hexChars[item>>4])
		builder.WriteByte(hexChars[item&0x0f])
	}
	return builder.String()
}
