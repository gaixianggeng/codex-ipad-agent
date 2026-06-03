package httpapi

import (
	"bufio"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/auth"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/codexhistory"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/doctor"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

//go:embed static/*
var staticFS embed.FS

type Router struct {
	cfg      config.Config
	projects *projects.Registry
	sessions *session.Manager
	runtime  SessionRuntime
	doctor   *doctor.Checker
	auth     auth.Authenticator
	version  string
	upgrader websocket.Upgrader

	gatewayThreadsMu sync.Mutex
	gatewayThreads   map[string]appServerGatewayAllowedThread
}

func NewRouter(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string) http.Handler {
	return NewRouterWithRuntime(cfg, registry, manager, checker, version, NewPTYSessionRuntime(registry, manager))
}

func NewRouterWithRuntime(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string, runtime SessionRuntime) http.Handler {
	if runtime == nil {
		runtime = NewPTYSessionRuntime(registry, manager)
	}
	r := &Router{
		cfg:      cfg,
		projects: registry,
		sessions: manager,
		runtime:  runtime,
		doctor:   checker,
		auth: auth.NewWithOptions(cfg.Auth.Token, cfg.DevInsecure, auth.Options{
			AllowQueryToken: cfg.Auth.AllowQueryToken,
		}),
		version: version,
		upgrader: websocket.Upgrader{
			CheckOrigin: sameOriginOrNoOrigin,
		},
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", r.healthz)
	mux.HandleFunc("/api/health", r.healthz)
	mux.Handle("/api/readyz", r.auth.Middleware(http.HandlerFunc(r.readyz)))
	mux.Handle("/api/version", r.auth.Middleware(http.HandlerFunc(r.versionHandler)))
	mux.Handle("/api/doctor", r.auth.Middleware(http.HandlerFunc(r.doctorHandler)))
	mux.Handle("/api/debug/codex-history", r.auth.Middleware(http.HandlerFunc(r.codexHistoryDebugHandler)))
	mux.Handle("/api/projects", r.auth.Middleware(http.HandlerFunc(r.projectsHandler)))
	mux.Handle("/api/app-server/config", r.auth.Middleware(http.HandlerFunc(r.appServerConfigHandler)))
	mux.Handle("/api/app-server/ws", r.auth.Middleware(http.HandlerFunc(r.appServerGatewayWS)))
	mux.Handle("/api/sessions", r.auth.Middleware(http.HandlerFunc(r.sessionsHandler)))
	mux.HandleFunc("/api/sessions/", r.sessionByIDHandler)
	mux.Handle("/", r.staticHandler())
	return logging(mux)
}

func sameOriginOrNoOrigin(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil {
		return false
	}
	return strings.EqualFold(parsed.Host, r.Host)
}

func (r *Router) staticHandler() http.Handler {
	sub, _ := fs.Sub(staticFS, "static")
	return http.FileServer(http.FS(sub))
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			log.Printf("%s %s status=%d bytes=%d duration=%s", r.Method, r.URL.RequestURI(), rec.status, rec.bytes, time.Since(start).Round(time.Millisecond))
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(data []byte) (int, error) {
	n, err := r.ResponseWriter.Write(data)
	r.bytes += n
	return n, err
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("response writer 不支持 hijack")
	}
	r.status = http.StatusSwitchingProtocols
	return hijacker.Hijack()
}

func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (r *Router) healthz(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": r.version})
}

func (r *Router) readyz(w http.ResponseWriter, req *http.Request) {
	results := r.doctor.Run(req.Context(), false)
	writeJSON(w, http.StatusOK, results)
}

func (r *Router) versionHandler(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"name": "agentd", "version": r.version})
}

func (r *Router) doctorHandler(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, r.doctor.Run(req.Context(), false))
}

func (r *Router) codexHistoryDebugHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	limit := positiveLimit(req.URL.Query().Get("limit"))
	if limit == 0 {
		limit = 80
	}
	projectID := strings.TrimSpace(req.URL.Query().Get("project_id"))
	writeJSON(w, http.StatusOK, codexhistory.Diagnose(r.projects, r.sessions.ListUnsorted(), projectID, limit))
}

func (r *Router) projectsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"projects": r.projects.List()})
}

func (r *Router) sessionsHandler(w http.ResponseWriter, req *http.Request) {
	switch req.Method {
	case http.MethodGet:
		projectID := strings.TrimSpace(req.URL.Query().Get("project_id"))
		limit := positiveLimit(req.URL.Query().Get("limit"))
		cursor, hasCursor, err := decodeSessionCursor(req.URL.Query().Get("cursor"))
		if err != nil {
			writeError(w, http.StatusBadRequest, "cursor 无效")
			return
		}
		page, err := r.runtime.ListSessions(req.Context(), projectID, limit, cursor, hasCursor)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		response := map[string]any{
			"sessions": page.Sessions,
			"has_more": page.HasMore,
		}
		if page.NextCursor != "" {
			response["next_cursor"] = page.NextCursor
		}
		writeJSON(w, http.StatusOK, response)
	case http.MethodPost:
		var body struct {
			ProjectID       string `json:"project_id"`
			Prompt          string `json:"prompt"`
			ResumeID        string `json:"resume_id"`
			Title           string `json:"title"`
			Cols            int    `json:"cols"`
			Rows            int    `json:"rows"`
			ClientMessageID string `json:"client_message_id"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 64*1024)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "请求 JSON 无效")
			return
		}
		project, ok := r.projects.Get(body.ProjectID)
		if !ok {
			writeError(w, http.StatusBadRequest, "项目不存在")
			return
		}
		log.Printf("create session project=%s resume=%s prompt_bytes=%d", body.ProjectID, body.ResumeID, len(body.Prompt))
		result, err := r.runtime.CreateSession(req.Context(), RuntimeCreateRequest{
			Project:         project,
			Prompt:          body.Prompt,
			ResumeID:        body.ResumeID,
			Title:           body.Title,
			Cols:            body.Cols,
			Rows:            body.Rows,
			ClientMessageID: body.ClientMessageID,
		})
		if err != nil {
			log.Printf("create session failed project=%s resume=%s err=%v", body.ProjectID, body.ResumeID, err)
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		log.Printf("created session id=%s source=%s status=%s resume=%s", result.Snapshot.ID, result.Snapshot.Source, result.Snapshot.Status, result.Snapshot.ResumeID)
		response := map[string]any{"session": result.Snapshot, "ws_url": "/api/sessions/" + result.Snapshot.ID + "/ws"}
		if body.ClientMessageID != "" {
			response["client_message_id"] = body.ClientMessageID
			if message, ok := userMessageConfirmation(result.Snapshot.ID, body.ClientMessageID, body.Prompt, time.Now().UTC()); ok {
				if result.LiveSession != nil {
					recordSubmittedUserMessage(result.LiveSession, message)
				}
				response["first_message"] = message
			}
		}
		writeJSON(w, http.StatusCreated, response)
	default:
		methodNotAllowed(w)
	}
}

type sessionPageCursor struct {
	ID          string `json:"id"`
	UpdatedAtMS int64  `json:"updated_at_ms"`
}

func decodeSessionCursor(raw string) (sessionPageCursor, bool, error) {
	if strings.TrimSpace(raw) == "" {
		return sessionPageCursor{}, false, nil
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return sessionPageCursor{}, false, err
	}
	var cursor sessionPageCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return sessionPageCursor{}, false, err
	}
	if cursor.ID == "" || cursor.UpdatedAtMS <= 0 {
		return sessionPageCursor{}, false, fmt.Errorf("invalid session cursor")
	}
	return cursor, true, nil
}

func encodeSessionCursor(item session.SessionSnapshot) string {
	cursor := sessionPageCursor{ID: item.ID, UpdatedAtMS: sessionUpdatedAtMS(item)}
	if cursor.ID == "" || cursor.UpdatedAtMS <= 0 {
		return ""
	}
	data, err := json.Marshal(cursor)
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

func activeSessionSnapshots(list []*session.Session, projectID string) []session.SessionSnapshot {
	return activeSessionSnapshotWindow(list, projectID, sessionPageCursor{}, false, 0)
}

func activeSessionSnapshotWindow(list []*session.Session, projectID string, cursor sessionPageCursor, hasCursor bool, limit int) []session.SessionSnapshot {
	capacity := len(list)
	if limit > 0 && limit < capacity {
		capacity = limit
	}
	out := make([]session.SessionSnapshot, 0, capacity)
	cursorID := ""
	cursorUpdatedAtMS := int64(0)
	if hasCursor {
		cursorID = cursor.ID
		cursorUpdatedAtMS = cursor.UpdatedAtMS
	}
	for _, item := range list {
		// 项目会话列表是 iPad 高频轮询入口，先按项目收窄再排序/分页，避免无关运行会话
		// 参与后续投影；全局列表仍保留所有 active session。
		if snapshot, ok := item.SnapshotIfProjectBeforeCursor(projectID, cursorID, cursorUpdatedAtMS); ok {
			out = appendSessionWindowCandidate(out, snapshot, limit)
		}
	}
	return out
}

func paginateSessions(items []session.SessionSnapshot, cursor sessionPageCursor, hasCursor bool, limit int) ([]session.SessionSnapshot, string, bool) {
	sortSessionsByUpdated(items)
	if hasCursor {
		filtered := items[:0]
		for _, item := range items {
			if sessionBeforeCursor(item, cursor) {
				filtered = append(filtered, item)
			}
		}
		items = filtered
	}
	if limit <= 0 || len(items) <= limit {
		return items, "", false
	}
	page := append([]session.SessionSnapshot(nil), items[:limit]...)
	return page, encodeSessionCursor(page[len(page)-1]), true
}

func sortSessionsByUpdated(items []session.SessionSnapshot) {
	sort.SliceStable(items, func(i, j int) bool {
		return sessionSortBefore(items[i], items[j])
	})
}

func appendSessionWindowCandidate(items []session.SessionSnapshot, candidate session.SessionSnapshot, limit int) []session.SessionSnapshot {
	if limit <= 0 {
		return append(items, candidate)
	}
	insertAt := len(items)
	for index, item := range items {
		if sessionSortBefore(candidate, item) {
			insertAt = index
			break
		}
	}
	if insertAt == len(items) && len(items) >= limit {
		return items
	}
	items = append(items, candidate)
	if insertAt < len(items)-1 {
		copy(items[insertAt+1:], items[insertAt:len(items)-1])
		items[insertAt] = candidate
	}
	if len(items) > limit {
		items = items[:limit]
	}
	return items
}

func sessionSortBefore(left, right session.SessionSnapshot) bool {
	leftUpdatedAt := sessionUpdatedAtMS(left)
	rightUpdatedAt := sessionUpdatedAtMS(right)
	if leftUpdatedAt == rightUpdatedAt {
		return left.ID > right.ID
	}
	return leftUpdatedAt > rightUpdatedAt
}

func sessionBeforeCursor(item session.SessionSnapshot, cursor sessionPageCursor) bool {
	updatedAtMS := sessionUpdatedAtMS(item)
	if updatedAtMS != cursor.UpdatedAtMS {
		return updatedAtMS < cursor.UpdatedAtMS
	}
	return item.ID < cursor.ID
}

func sessionUpdatedAtMS(item session.SessionSnapshot) int64 {
	if !item.UpdatedAt.IsZero() {
		return item.UpdatedAt.UnixMilli()
	}
	if !item.CreatedAt.IsZero() {
		return item.CreatedAt.UnixMilli()
	}
	return 0
}

func positiveLimit(raw string) int {
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return 0
	}
	if n > 300 {
		return 300
	}
	return n
}

func (r *Router) sessionByIDHandler(w http.ResponseWriter, req *http.Request) {
	if !r.auth.ValidRequest(req) {
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	path := strings.TrimPrefix(req.URL.Path, "/api/sessions/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		http.NotFound(w, req)
		return
	}
	id := parts[0]
	if len(parts) == 2 && parts[1] == "messages" {
		r.sessionMessages(w, req, id)
		return
	}
	if len(parts) == 2 && parts[1] == "trace" {
		r.sessionTrace(w, req, id)
		return
	}
	if len(parts) == 2 && parts[1] == "ws" {
		r.sessionWS(w, req, id)
		return
	}
	if len(parts) != 1 {
		http.NotFound(w, req)
		return
	}
	switch req.Method {
	case http.MethodGet:
		detail, err := r.runtime.SessionDetail(req.Context(), id, positiveSeq(req.URL.Query().Get("after_seq")))
		if err != nil {
			writeError(w, http.StatusNotFound, "session 不存在")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"session":       detail.Snapshot,
			"recent_output": detail.RecentOutput,
			"last_seq":      detail.LastSeq,
		})
	case http.MethodDelete:
		if err := r.runtime.StopSession(req.Context(), id); err != nil {
			writeError(w, http.StatusNotFound, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		methodNotAllowed(w)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"error": message})
}

func methodNotAllowed(w http.ResponseWriter) {
	writeError(w, http.StatusMethodNotAllowed, "method not allowed")
}

func (r *Router) sessionTrace(w http.ResponseWriter, req *http.Request, id string) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	trace, err := r.runtime.SessionTrace(req.Context(), id)
	if err != nil {
		writeError(w, http.StatusNotFound, "session 不存在")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"trace": trace})
}

func (r *Router) sessionMessages(w http.ResponseWriter, req *http.Request, id string) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	limit := positiveLimit(req.URL.Query().Get("limit"))
	before := strings.TrimSpace(req.URL.Query().Get("before"))
	page, err := r.runtime.SessionMessages(req.Context(), id, before, limit)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"messages":        page.Messages,
		"previous_cursor": page.PreviousCursor,
		"has_more_before": page.HasMoreBefore,
	})
}
