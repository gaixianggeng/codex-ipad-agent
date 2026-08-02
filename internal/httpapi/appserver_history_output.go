package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

const appServerHistoryOutputURLPrefix = "agentd-history-output://"

var (
	appServerHistoryOutputTTL                = 30 * time.Minute
	appServerHistoryOutputMaxEntries         = 4096
	appServerHistoryOutputMaxBytes     int64 = 256 << 20
	appServerHistoryOutputMaxItemBytes int64 = 64 << 20
	appServerHistoryOutputMinItemBytes       = 2 << 10
	appServerHistoryOutputPreviewBytes       = 1 << 10
)

func newAppServerHistoryOutputStore() *appServerHistoryMediaStore {
	return newAppServerHistoryBlobStore(
		appServerHistoryOutputTTL,
		appServerHistoryOutputMaxEntries,
		appServerHistoryOutputMaxBytes,
		appServerHistoryOutputMaxItemBytes,
	)
}

func (r *Router) appServerHistoryOutputHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(req.URL.Path, "/api/app-server/history-output/"))
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusBadRequest, "history output id 无效")
		return
	}
	if r == nil || r.historyOutput == nil {
		writeError(w, http.StatusNotFound, "history output 已过期或不存在")
		return
	}
	entry, ok := r.historyOutput.get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "history output 已过期或不存在")
		return
	}
	writeJSON(w, http.StatusOK, fileReadResponse{
		Path:          appServerHistoryOutputURLPrefix + entry.id,
		Name:          "history-output-" + entry.id + historyOutputFilenameSuffix(entry.contentType),
		ContentType:   entry.contentType,
		Size:          int64(len(entry.data)),
		ContentBase64: base64.StdEncoding.EncodeToString(entry.data),
	})
}

func historyOutputFilenameSuffix(contentType string) string {
	if strings.EqualFold(strings.TrimSpace(strings.Split(contentType, ";")[0]), "application/json") {
		return ".json"
	}
	return ".txt"
}

// dehydrateOversizedHistoryOutputs 只处理已超过 gateway full cap 的响应。
// 它不裁剪用户/助手消息，只把可恢复的过程输出外置到短期、鉴权的缓存；
// 老客户端仍能读到原字段中的短预览，新客户端可按需打开完整内容。
func (r *Router) dehydrateOversizedHistoryOutputs(payload []byte) ([]byte, bool) {
	if r == nil || r.historyOutput == nil || len(payload) == 0 {
		return payload, false
	}
	if !bytes.Contains(payload, []byte(`"commandExecution"`)) &&
		!bytes.Contains(payload, []byte(`"mcpToolCall"`)) &&
		!bytes.Contains(payload, []byte(`"dynamicToolCall"`)) &&
		!bytes.Contains(payload, []byte(`"collabAgentToolCall"`)) &&
		!bytes.Contains(payload, []byte(`"webSearch"`)) &&
		!bytes.Contains(payload, []byte(`"fileChange"`)) {
		return payload, false
	}

	var root any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&root); err != nil {
		return payload, false
	}
	if !r.dehydrateHistoryOutputValue(root) {
		return payload, false
	}
	rewritten, err := json.Marshal(root)
	if err != nil || len(rewritten) >= len(payload) {
		return payload, false
	}
	return rewritten, true
}

func (r *Router) dehydrateHistoryOutputValue(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		changed := r.dehydrateHistoryOutputItem(typed)
		for _, child := range typed {
			if r.dehydrateHistoryOutputValue(child) {
				changed = true
			}
		}
		return changed
	case []any:
		changed := false
		for _, child := range typed {
			if r.dehydrateHistoryOutputValue(child) {
				changed = true
			}
		}
		return changed
	default:
		return false
	}
}

func (r *Router) dehydrateHistoryOutputItem(item map[string]any) bool {
	if _, alreadyRedacted := item["historyOutputRef"]; alreadyRedacted {
		return false
	}
	typeName, _ := item["type"].(string)
	typeName = strings.TrimSpace(typeName)

	var (
		data        []byte
		contentType string
		preview     string
		replace     func()
	)
	switch typeName {
	case "commandExecution":
		output, _ := item["aggregatedOutput"].(string)
		data = []byte(output)
		contentType = "text/plain; charset=utf-8"
		preview = historyOutputPreview(data)
		replace = func() { item["aggregatedOutput"] = preview }
	case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
		result, ok := item["result"]
		if !ok || result == nil {
			return false
		}
		if text, ok := result.(string); ok {
			data = []byte(text)
			contentType = "text/plain; charset=utf-8"
		} else {
			data, _ = json.Marshal(result)
			contentType = "application/json"
		}
		preview = historyOutputPreview(data)
		replace = func() { item["result"] = preview }
	case "fileChange":
		changes, ok := item["changes"].([]any)
		if !ok || len(changes) == 0 {
			return false
		}
		data, _ = json.Marshal(changes)
		contentType = "application/json"
		preview = historyOutputPreview(data)
		replace = func() { item["changes"] = compactHistoryFileChanges(changes) }
	default:
		return false
	}
	if len(data) < appServerHistoryOutputMinItemBytes || replace == nil {
		return false
	}
	id, ok := r.historyOutput.put(contentType, data)
	if !ok {
		return false
	}
	replace()
	item["historyOutputRef"] = appServerHistoryOutputURLPrefix + id
	item["historyOutputByteCount"] = len(data)
	item["historyOutputContentType"] = contentType
	item["historyOutputPreview"] = preview
	item["historyOutputRedacted"] = true
	return true
}

func compactHistoryFileChanges(changes []any) []any {
	compact := make([]any, 0, len(changes))
	for _, value := range changes {
		change, ok := value.(map[string]any)
		if !ok {
			continue
		}
		entry := map[string]any{}
		for _, key := range []string{"path", "filePath", "relativePath", "filename", "kind", "status"} {
			if value, ok := change[key]; ok {
				entry[key] = value
			}
		}
		if len(entry) > 0 {
			compact = append(compact, entry)
		}
	}
	return compact
}

func historyOutputPreview(data []byte) string {
	if len(data) <= appServerHistoryOutputPreviewBytes {
		return string(data)
	}
	limit := appServerHistoryOutputPreviewBytes
	// UTF-8 多字节字符不能从中间截断，否则 JSON 重编码后会出现替换字符。
	for limit > 0 && (data[limit]&0xc0) == 0x80 {
		limit--
	}
	return string(data[:limit])
}
