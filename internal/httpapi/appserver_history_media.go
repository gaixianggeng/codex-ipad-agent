package httpapi

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"
)

const appServerHistoryMediaURLPrefix = "agentd-history-media://"

var (
	appServerHistoryMediaTTL                = 30 * time.Minute
	appServerHistoryMediaMaxEntries         = 128
	appServerHistoryMediaMaxBytes     int64 = 256 << 20
	appServerHistoryMediaMaxItemBytes int64 = 20 << 20
)

// imageGeneration.result 之类的裸 base64 只有大到影响 gateway cap / 隧道带宽时才值得改写；
// 小图继续内联，避免为几 KB 的内容多一次往返。
var appServerHistoryMediaMinRawBase64Chars = 16 << 10

type appServerHistoryMediaStore struct {
	mu         sync.Mutex
	entries    map[string]appServerHistoryMediaEntry
	totalBytes int64
}

type appServerHistoryMediaEntry struct {
	id          string
	contentType string
	data        []byte
	createdAt   time.Time
	lastAccess  time.Time
}

func newAppServerHistoryMediaStore() *appServerHistoryMediaStore {
	return &appServerHistoryMediaStore{entries: map[string]appServerHistoryMediaEntry{}}
}

func (s *appServerHistoryMediaStore) put(contentType string, data []byte) (string, bool) {
	if s == nil || len(data) == 0 || int64(len(data)) > appServerHistoryMediaMaxItemBytes {
		return "", false
	}
	id, ok := randomHistoryMediaID()
	if !ok {
		return "", false
	}
	now := time.Now()
	entry := appServerHistoryMediaEntry{
		id:          id,
		contentType: contentType,
		data:        append([]byte(nil), data...),
		createdAt:   now,
		lastAccess:  now,
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	s.entries[id] = entry
	s.totalBytes += int64(len(entry.data))
	s.enforceLimitsLocked(now)
	return id, true
}

func (s *appServerHistoryMediaStore) get(id string) (appServerHistoryMediaEntry, bool) {
	if s == nil {
		return appServerHistoryMediaEntry{}, false
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return appServerHistoryMediaEntry{}, false
	}
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	entry, ok := s.entries[id]
	if !ok {
		return appServerHistoryMediaEntry{}, false
	}
	entry.lastAccess = now
	s.entries[id] = entry
	return entry, true
}

func (s *appServerHistoryMediaStore) pruneLocked(now time.Time) {
	if appServerHistoryMediaTTL <= 0 {
		return
	}
	for id, entry := range s.entries {
		if now.Sub(entry.createdAt) > appServerHistoryMediaTTL {
			delete(s.entries, id)
			s.totalBytes -= int64(len(entry.data))
		}
	}
	if s.totalBytes < 0 {
		s.totalBytes = 0
	}
}

func (s *appServerHistoryMediaStore) enforceLimitsLocked(now time.Time) {
	for (appServerHistoryMediaMaxEntries > 0 && len(s.entries) > appServerHistoryMediaMaxEntries) ||
		(appServerHistoryMediaMaxBytes > 0 && s.totalBytes > appServerHistoryMediaMaxBytes) {
		oldestID := ""
		oldestAt := now
		for id, entry := range s.entries {
			if oldestID == "" || entry.lastAccess.Before(oldestAt) {
				oldestID = id
				oldestAt = entry.lastAccess
			}
		}
		if oldestID == "" {
			return
		}
		entry := s.entries[oldestID]
		delete(s.entries, oldestID)
		s.totalBytes -= int64(len(entry.data))
	}
	if s.totalBytes < 0 {
		s.totalBytes = 0
	}
}

func randomHistoryMediaID() (string, bool) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", false
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), true
}

func (r *Router) appServerHistoryMediaHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	id := strings.TrimPrefix(req.URL.Path, "/api/app-server/history-media/")
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusBadRequest, "history media id 无效")
		return
	}
	entry, ok := r.historyMedia.get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "history media 已过期或不存在")
		return
	}
	writeJSON(w, http.StatusOK, fileReadResponse{
		Path:          appServerHistoryMediaURLPrefix + entry.id,
		Name:          historyMediaFilename(entry.id, entry.contentType),
		ContentType:   entry.contentType,
		Size:          int64(len(entry.data)),
		ContentBase64: base64.StdEncoding.EncodeToString(entry.data),
	})
}

func (r *Router) redactInlineHistoryImagesInGatewayResponse(payload []byte) ([]byte, bool) {
	if r == nil || r.historyMedia == nil {
		return payload, false
	}
	if !bytes.Contains(payload, []byte("data:image/")) && !bytes.Contains(payload, []byte(`"imageGeneration"`)) {
		return payload, false
	}
	var root any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&root); err != nil {
		return payload, false
	}
	if !r.redactInlineHistoryImagesValue(root) {
		return payload, false
	}
	rewritten, err := json.Marshal(root)
	if err != nil {
		return payload, false
	}
	return rewritten, true
}

func (r *Router) redactInlineHistoryImagesValue(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		changed := r.redactInlineHistoryImageObject(typed)
		if r.redactInlineHistoryImageGenerationObject(typed) {
			changed = true
		}
		for _, child := range typed {
			if r.redactInlineHistoryImagesValue(child) {
				changed = true
			}
		}
		return changed
	case []any:
		changed := false
		for _, child := range typed {
			if r.redactInlineHistoryImagesValue(child) {
				changed = true
			}
		}
		return changed
	default:
		return false
	}
}

func (r *Router) redactInlineHistoryImageObject(object map[string]any) bool {
	rawType, _ := object["type"].(string)
	if strings.TrimSpace(rawType) != "image" {
		return false
	}
	rawURL, _ := object["url"].(string)
	contentType, data, ok := decodeHistoryImageDataURL(rawURL)
	if !ok {
		return false
	}
	id, ok := r.historyMedia.put(contentType, data)
	if !ok {
		return false
	}
	// 核心逻辑：历史 full 响应里的 inline 图片对首屏文字没有必要，
	// 先替换成短 URL，避免大 base64 把 gateway 历史 cap 撞爆。
	object["url"] = appServerHistoryMediaURLPrefix + id
	object["contentType"] = contentType
	object["byteCount"] = len(data)
	object["redacted"] = true
	return true
}

// imageGeneration item 的 result 字段是不带 data: 前缀的裸 base64 整图（旁边有 savedPath），
// 单张 1-2MB，是历史 full 响应撞 cap 的最大来源；iPad 端不消费该字段，改写成短 URL 零损失。
func (r *Router) redactInlineHistoryImageGenerationObject(object map[string]any) bool {
	rawType, _ := object["type"].(string)
	if strings.TrimSpace(rawType) != "imageGeneration" {
		return false
	}
	rawResult, _ := object["result"].(string)
	contentType, data, ok := decodeHistoryRawBase64Image(rawResult)
	if !ok {
		return false
	}
	id, ok := r.historyMedia.put(contentType, data)
	if !ok {
		return false
	}
	object["result"] = appServerHistoryMediaURLPrefix + id
	object["resultContentType"] = contentType
	object["resultByteCount"] = len(data)
	object["resultRedacted"] = true
	return true
}

func decodeHistoryRawBase64Image(value string) (string, []byte, bool) {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) < appServerHistoryMediaMinRawBase64Chars {
		return "", nil, false
	}
	if strings.HasPrefix(strings.ToLower(trimmed), "data:") {
		return "", nil, false
	}
	data, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil || len(data) == 0 {
		return "", nil, false
	}
	contentType := http.DetectContentType(data)
	if !strings.HasPrefix(contentType, "image/") {
		return "", nil, false
	}
	return contentType, data, true
}

func decodeHistoryImageDataURL(value string) (string, []byte, bool) {
	trimmed := strings.TrimSpace(value)
	if !strings.HasPrefix(strings.ToLower(trimmed), "data:image/") {
		return "", nil, false
	}
	comma := strings.Index(trimmed, ",")
	if comma <= len("data:") {
		return "", nil, false
	}
	metadata := trimmed[len("data:"):comma]
	parts := strings.Split(metadata, ";")
	contentType := strings.TrimSpace(parts[0])
	if !strings.HasPrefix(strings.ToLower(contentType), "image/") {
		return "", nil, false
	}
	isBase64 := false
	for _, part := range parts[1:] {
		if strings.EqualFold(strings.TrimSpace(part), "base64") {
			isBase64 = true
			break
		}
	}
	if !isBase64 {
		return "", nil, false
	}
	data, err := base64.StdEncoding.DecodeString(trimmed[comma+1:])
	if err != nil || len(data) == 0 {
		return "", nil, false
	}
	return contentType, data, true
}

func historyMediaFilename(id, contentType string) string {
	switch strings.ToLower(strings.TrimSpace(contentType)) {
	case "image/png":
		return "history-" + id + ".png"
	case "image/jpeg", "image/jpg":
		return "history-" + id + ".jpg"
	case "image/gif":
		return "history-" + id + ".gif"
	case "image/webp":
		return "history-" + id + ".webp"
	default:
		return "history-" + id + ".bin"
	}
}
