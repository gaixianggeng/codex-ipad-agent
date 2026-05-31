package httpapi

import (
	"embed"
	"encoding/json"
	"io/fs"
	"net/http"
	"strconv"
	"strings"
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
	doctor   *doctor.Checker
	auth     auth.Authenticator
	version  string
	upgrader websocket.Upgrader
}

func NewRouter(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string) http.Handler {
	r := &Router{
		cfg:      cfg,
		projects: registry,
		sessions: manager,
		doctor:   checker,
		auth:     auth.New(cfg.Auth.Token, cfg.DevInsecure),
		version:  version,
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool {
				// 单机/Tailscale 场景下，真正的保护边界是 Bearer Token。
				return true
			},
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", r.healthz)
	mux.HandleFunc("/api/health", r.healthz)
	mux.Handle("/api/readyz", r.auth.Middleware(http.HandlerFunc(r.readyz)))
	mux.Handle("/api/version", r.auth.Middleware(http.HandlerFunc(r.versionHandler)))
	mux.Handle("/api/doctor", r.auth.Middleware(http.HandlerFunc(r.doctorHandler)))
	mux.Handle("/api/projects", r.auth.Middleware(http.HandlerFunc(r.projectsHandler)))
	mux.Handle("/api/sessions", r.auth.Middleware(http.HandlerFunc(r.sessionsHandler)))
	mux.HandleFunc("/api/sessions/", r.sessionByIDHandler)
	mux.Handle("/", r.staticHandler())
	return logging(mux)
}

func (r *Router) staticHandler() http.Handler {
	sub, _ := fs.Sub(staticFS, "static")
	return http.FileServer(http.FS(sub))
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		_ = start
	})
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
		list := r.sessions.List()
		out := make([]session.Session, 0, len(list))
		for _, item := range list {
			out = append(out, item.Snapshot())
		}
		out = append(out, codexhistory.Load(r.projects, list)...)
		out = filterSessions(out, projectID)
		if limit > 0 && len(out) > limit {
			out = out[:limit]
		}
		writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
	case http.MethodPost:
		var body struct {
			ProjectID string `json:"project_id"`
			Prompt    string `json:"prompt"`
			ResumeID  string `json:"resume_id"`
			Title     string `json:"title"`
			Cols      int    `json:"cols"`
			Rows      int    `json:"rows"`
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
		s, err := r.sessions.Create(session.CreateRequest{Project: project, Prompt: body.Prompt, ResumeID: body.ResumeID, Title: body.Title, Cols: body.Cols, Rows: body.Rows})
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusCreated, map[string]any{"session": s.Snapshot(), "ws_url": "/api/sessions/" + s.ID + "/ws"})
	default:
		methodNotAllowed(w)
	}
}

func filterSessions(items []session.Session, projectID string) []session.Session {
	if projectID == "" {
		return items
	}
	out := make([]session.Session, 0, len(items))
	for _, item := range items {
		if item.ProjectID == projectID {
			out = append(out, item)
		}
	}
	return out
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
		s, ok := r.sessions.Get(id)
		if !ok {
			writeError(w, http.StatusNotFound, "session 不存在")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"session": s.Snapshot(), "recent_output": s.RecentOutput()})
	case http.MethodDelete:
		if err := r.sessions.Stop(id); err != nil {
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

func (r *Router) sessionMessages(w http.ResponseWriter, req *http.Request, id string) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if strings.HasPrefix(id, "codex_") {
		messages, err := codexhistory.Messages(strings.TrimPrefix(id, "codex_"))
		if err != nil {
			writeError(w, http.StatusNotFound, "读取 Codex 历史失败")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"messages": messages})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": []any{}})
}
