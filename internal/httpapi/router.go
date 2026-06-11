package httpapi

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
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

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

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
	return NewRouterWithRuntime(cfg, registry, manager, checker, version, nil)
}

func NewRouterWithRuntime(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string, runtime SessionRuntime) http.Handler {
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
	if cfg.Debug.EnableCodexHistory {
		mux.Handle("/api/debug/codex-history", r.auth.Middleware(http.HandlerFunc(r.codexHistoryDebugHandler)))
	} else {
		mux.HandleFunc("/api/debug/codex-history", r.codexHistoryDebugDisabledHandler)
	}
	mux.Handle("/api/projects", r.auth.Middleware(http.HandlerFunc(r.projectsHandler)))
	mux.Handle("/api/workspaces/resolve", r.auth.Middleware(http.HandlerFunc(r.workspaceResolveHandler)))
	mux.Handle("/api/directories/list", r.auth.Middleware(http.HandlerFunc(r.directoryListHandler)))
	mux.Handle("/api/app-server/config", r.auth.Middleware(http.HandlerFunc(r.appServerConfigHandler)))
	mux.Handle("/api/app-server/ws", r.auth.Middleware(http.HandlerFunc(r.appServerGatewayWS)))
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

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			log.Printf("%s %s remote=%s host=%s status=%d bytes=%d duration=%s", r.Method, redactedRequestURI(r.URL), requestRemoteHost(r), r.Host, rec.status, rec.bytes, time.Since(start).Round(time.Millisecond))
		}
	})
}

func redactedRequestURI(u *url.URL) string {
	if u == nil {
		return ""
	}
	next := *u
	query := next.Query()
	for key := range query {
		switch strings.ToLower(key) {
		case "token", "access_token", "authorization":
			query.Set(key, "<redacted>")
		}
	}
	next.RawQuery = query.Encode()
	return next.RequestURI()
}

func requestRemoteHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
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
	if !r.cfg.Debug.EnableCodexHistory {
		writeError(w, http.StatusNotFound, "codex history debug endpoint disabled")
		return
	}
	limit := positiveLimit(req.URL.Query().Get("limit"))
	if limit == 0 {
		limit = 80
	}
	projectID := strings.TrimSpace(req.URL.Query().Get("project_id"))
	writeJSON(w, http.StatusOK, codexhistory.Diagnose(r.projects, r.sessions.ListUnsorted(), projectID, limit))
}

func (r *Router) codexHistoryDebugDisabledHandler(w http.ResponseWriter, req *http.Request) {
	writeError(w, http.StatusNotFound, "not found")
}

func (r *Router) projectsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	projectList := r.projects.List()
	log.Printf("projects response remote=%s host=%s projects=%d", requestRemoteHost(req), req.Host, len(projectList))
	writeJSON(w, http.StatusOK, map[string]any{"projects": projectList})
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
