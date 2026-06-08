package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/codex-ipad-agent/internal/appserver"
	"github.com/gaixianggeng/codex-ipad-agent/internal/projects"
)

const (
	appServerGatewayPath           = "/api/app-server/ws"
	appServerPolicyErrorCode       = -32080
	appServerGatewayWriteWindow    = 10 * time.Second
	appServerGatewayThreadCacheMax = 2048
	appServerGatewayThreadCacheTTL = 24 * time.Hour
)

var appServerAllowedMethods = map[string]struct{}{
	"initialize":              {},
	"initialized":             {},
	"thread/list":             {},
	"thread/start":            {},
	"thread/resume":           {},
	"thread/read":             {},
	"turn/start":              {},
	"turn/interrupt":          {},
	"model/list":              {},
	"account/rateLimits/read": {},
}

type appServerConfigResponse struct {
	GatewayWSURL string                   `json:"gateway_ws_url"`
	Runtime      appServerRuntimeMetadata `json:"runtime"`
	Projects     []projects.Project       `json:"projects"`
	Policy       appServerPolicyMetadata  `json:"policy"`
}

type appServerRuntimeMetadata struct {
	Type               string `json:"type"`
	Transport          string `json:"transport"`
	Managed            bool   `json:"managed"`
	GatewayAvailable   bool   `json:"gateway_available"`
	UpstreamConfigured bool   `json:"upstream_configured"`
	Running            bool   `json:"running"`
	Initialized        bool   `json:"initialized"`
	PendingRequests    int    `json:"pending_requests"`
}

type appServerPolicyMetadata struct {
	AllowedMethods []string `json:"allowed_methods"`
	ProjectsSource string   `json:"projects_source"`
}

type appServerDiagnosticsProvider interface {
	AppServerDiagnostics() appserver.Diagnostics
}

type appServerGatewayFrame struct {
	ID     *json.RawMessage `json:"id,omitempty"`
	Method string           `json:"method,omitempty"`
	Params json.RawMessage  `json:"params,omitempty"`
	Result json.RawMessage  `json:"result,omitempty"`
	Error  json.RawMessage  `json:"error,omitempty"`
}

type appServerGatewayPolicyError struct {
	id      *json.RawMessage
	message string
}

type appServerGatewayPolicy struct {
	router *Router
	mu     sync.Mutex

	pendingThreads map[string]appServerGatewayPendingThreadRequest
	allowedThreads map[string]appServerGatewayAllowedThread
}

type appServerGatewayPendingThreadRequest struct {
	method    string
	cwd       string
	projectID string
}

type appServerGatewayValidatedParams struct {
	cwd          string
	hasCWD       bool
	cwdProject   projects.Project
	cwdProjectOK bool
}

type appServerGatewayAllowedThread struct {
	id        string
	cwd       string
	projectID string
	lastSeen  time.Time
}

type appServerGatewayThreadWire struct {
	ID        string `json:"id"`
	ThreadID  string `json:"threadId"`
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
	Path      string `json:"path"`
}

func (r *Router) appServerConfigHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	projectList := r.projects.List()
	runtimeMeta := r.appServerRuntimeMetadata()
	log.Printf("app-server config response remote=%s host=%s projects=%d transport=%s gateway_available=%t", requestRemoteHost(req), req.Host, len(projectList), runtimeMeta.Transport, runtimeMeta.GatewayAvailable)
	writeJSON(w, http.StatusOK, appServerConfigResponse{
		GatewayWSURL: r.appServerGatewayURL(req),
		Runtime:      runtimeMeta,
		Projects:     projectList,
		Policy: appServerPolicyMetadata{
			AllowedMethods: appServerAllowedMethodList(),
			ProjectsSource: "agentd_allowlist",
		},
	})
}

func (r *Router) appServerRuntimeMetadata() appServerRuntimeMetadata {
	upstream, _ := r.appServerUpstreamWebSocketURL()
	meta := appServerRuntimeMetadata{
		Type:               firstNonEmpty(r.cfg.Runtime.Type, "codex_app_server"),
		Transport:          firstNonEmpty(r.cfg.AppServer.Transport, "ws"),
		Managed:            r.cfg.AppServer.Managed,
		GatewayAvailable:   upstream != "",
		UpstreamConfigured: strings.TrimSpace(r.cfg.AppServer.Listen) != "",
	}
	if provider, ok := r.runtime.(appServerDiagnosticsProvider); ok {
		// metadata 只暴露运行态计数，不返回 codex home、token 或 stderr 等敏感细节。
		diag := provider.AppServerDiagnostics()
		meta.Running = diag.Running
		meta.Initialized = diag.Initialized
		meta.PendingRequests = diag.PendingRequests
	}
	return meta
}

func appServerAllowedMethodList() []string {
	methods := make([]string, 0, len(appServerAllowedMethods))
	for method := range appServerAllowedMethods {
		methods = append(methods, method)
	}
	sort.Strings(methods)
	return methods
}

func (r *Router) appServerGatewayURL(req *http.Request) string {
	scheme := "ws"
	if req.TLS != nil || strings.EqualFold(req.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "wss"
	}
	host := req.Host
	if strings.TrimSpace(host) == "" {
		host = r.cfg.Listen
	}
	return (&url.URL{Scheme: scheme, Host: host, Path: appServerGatewayPath}).String()
}

func (r *Router) appServerGatewayWS(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !sameOriginOrNoOrigin(req) {
		writeError(w, http.StatusForbidden, "Origin 不允许访问 app-server gateway")
		return
	}
	upstreamURL, err := r.appServerUpstreamWebSocketURL()
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	upstreamHeaders, err := r.appServerUpstreamHeaders()
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	// 上游是 loopback app-server，就绪时握手是亚毫秒级；冷启动上游还没起来时，端口未监听会立刻
	// ECONNREFUSED，只有“端口已开但还没接受握手”才会卡到这里。把超时收紧到 4s，让 iPad 端能更快
	// 拿到 502 重试，而不是每次都白等 10s。
	dialer := websocket.Dialer{HandshakeTimeout: 4 * time.Second}
	upstream, _, err := dialer.DialContext(req.Context(), upstreamURL, upstreamHeaders)
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("连接 app-server gateway 上游失败：%v", err))
		return
	}
	defer upstream.Close()

	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("app-server gateway ws upgrade failed err=%v", err)
		return
	}
	defer client.Close()

	log.Printf("app-server gateway connected upstream=%s", sanitizeGatewayURL(upstreamURL))
	r.proxyAppServerGateway(req.Context(), client, upstream)
}

func (r *Router) appServerUpstreamWebSocketURL() (string, error) {
	raw := strings.TrimSpace(r.cfg.AppServer.Listen)
	if raw == "" {
		return "", fmt.Errorf("app_server.listen 未配置，无法启用 app-server raw gateway")
	}
	if !strings.Contains(raw, "://") {
		raw = "ws://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("app_server.listen 不是合法 URL：%w", err)
	}
	switch parsed.Scheme {
	case "ws", "wss":
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	default:
		return "", fmt.Errorf("app_server.listen 仅支持 ws/wss/http/https")
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("app_server.listen 缺少 host")
	}
	if !isLoopbackGatewayHost(parsed.Hostname()) {
		return "", fmt.Errorf("app_server.listen 只允许 loopback upstream")
	}
	if parsed.Path == "" {
		parsed.Path = "/"
	}
	return parsed.String(), nil
}

func isLoopbackGatewayHost(host string) bool {
	host = strings.TrimSpace(host)
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (r *Router) appServerUpstreamHeaders() (http.Header, error) {
	tokenFile := strings.TrimSpace(r.cfg.AppServer.WSTokenFile)
	if tokenFile == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(tokenFile)
	if err != nil {
		return nil, fmt.Errorf("读取 app_server.ws_token_file 失败：%w", err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return nil, fmt.Errorf("app_server.ws_token_file 为空")
	}
	headers := http.Header{}
	// app-server upstream capability token 和 iPad 访问 agentd 的 token 分离，避免把外侧 token 复用到本机上游。
	headers.Set("Authorization", "Bearer "+token)
	return headers, nil
}

func (r *Router) proxyAppServerGateway(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn) {
	done := make(chan struct{}, 2)
	var clientWriteMu sync.Mutex
	policy := &appServerGatewayPolicy{
		router:         r,
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads: map[string]appServerGatewayAllowedThread{},
	}

	go func() {
		defer func() { done <- struct{}{} }()
		r.copyClientFramesToAppServer(client, upstream, &clientWriteMu, policy)
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		copyWebSocketFrames(ctx, upstream, client, &clientWriteMu, policy)
	}()

	<-done
	_ = client.Close()
	_ = upstream.Close()
}

func (r *Router) copyClientFramesToAppServer(client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, policy *appServerGatewayPolicy) {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return
		}
		if policyErr := policy.validateClientFrame(messageType, payload); policyErr != nil {
			// 非法请求只回 JSON-RPC error，不把高危帧送到 app-server。
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return
			}
			continue
		}
		if err := writeWebSocketFrame(upstream, nil, messageType, payload); err != nil {
			return
		}
	}
}

func copyWebSocketFrames(ctx context.Context, from *websocket.Conn, to *websocket.Conn, toWriteMu *sync.Mutex, policy *appServerGatewayPolicy) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		messageType, payload, err := from.ReadMessage()
		if err != nil {
			return
		}
		// app-server 响应和通知是业务协议，gateway 只做原样转发。
		policy.observeUpstreamFrame(messageType, payload)
		if err := writeWebSocketFrame(to, toWriteMu, messageType, payload); err != nil {
			return
		}
	}
}

func writeWebSocketFrame(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	return conn.WriteMessage(messageType, payload)
}

func (p *appServerGatewayPolicy) validateClientFrame(messageType int, payload []byte) *appServerGatewayPolicyError {
	if messageType != websocket.TextMessage {
		return &appServerGatewayPolicyError{message: "app-server gateway 只允许 JSON text frame"}
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return &appServerGatewayPolicyError{message: "JSON-RPC frame 无效"}
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" {
		if frame.ID != nil && (len(frame.Result) > 0 || len(frame.Error) > 0) {
			return nil
		}
		return &appServerGatewayPolicyError{id: frame.ID, message: "JSON-RPC frame 缺少 method"}
	}
	if method != "initialized" && frame.ID == nil {
		return &appServerGatewayPolicyError{message: "app-server request 必须包含 id"}
	}
	if _, ok := appServerAllowedMethods[method]; !ok {
		return &appServerGatewayPolicyError{id: frame.ID, message: "app-server method 不允许：" + method}
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	validated, err := p.router.validateGatewayPolicyParams(method, params)
	if err != nil {
		return &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if err := p.validateThreadCapability(&frame, method, params, validated); err != nil {
		return &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	return nil
}

func (p *appServerGatewayPolicy) validateThreadCapability(frame *appServerGatewayFrame, method string, params map[string]any, validated appServerGatewayValidatedParams) error {
	cwd := validated.cwd
	project := validated.cwdProject
	projectOK := validated.cwdProjectOK

	switch method {
	case "thread/list", "thread/start":
		p.rememberPendingThreadResponse(frame.ID, method, cwd, project.ID)
	case "thread/resume":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		p.rememberPendingThreadResponse(frame.ID, method, cwd, project.ID)
	case "thread/read":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		p.rememberPendingThreadResponse(frame.ID, method, "", "")
	case "turn/start":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if !projectOK || project.ID != thread.projectID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的项目", method)
		}
	case "turn/interrupt":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
	}
	return nil
}

func (p *appServerGatewayPolicy) rememberPendingThreadResponse(id *json.RawMessage, method string, cwd string, projectID string) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return
	}
	p.mu.Lock()
	p.pendingThreads[key] = appServerGatewayPendingThreadRequest{method: method, cwd: cwd, projectID: projectID}
	p.mu.Unlock()
}

func (p *appServerGatewayPolicy) allowedThread(threadID string) (appServerGatewayAllowedThread, bool) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	p.mu.Lock()
	thread, ok := p.allowedThreads[threadID]
	p.mu.Unlock()
	if ok {
		return thread, true
	}
	return p.router.gatewayThread(threadID)
}

func (r *Router) gatewayThread(threadID string) (appServerGatewayAllowedThread, bool) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	now := time.Now()
	r.gatewayThreadsMu.Lock()
	defer r.gatewayThreadsMu.Unlock()
	thread, ok := r.gatewayThreads[threadID]
	if !ok {
		return appServerGatewayAllowedThread{}, false
	}
	if gatewayThreadCacheExpired(thread, now) {
		delete(r.gatewayThreads, threadID)
		return appServerGatewayAllowedThread{}, false
	}
	// 全局授权表只服务断线重连的短期恢复；命中时刷新 lastSeen，让活跃 thread 不被容量裁剪误删。
	thread.lastSeen = now
	r.gatewayThreads[threadID] = thread
	return thread, ok
}

func (p *appServerGatewayPolicy) observeUpstreamFrame(messageType int, payload []byte) {
	if messageType != websocket.TextMessage {
		return
	}
	if !p.hasPendingThreadResponses() {
		return
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return
	}
	if frame.ID == nil || len(frame.Result) == 0 || len(frame.Error) > 0 {
		p.forgetPending(frame.ID)
		return
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	if ok {
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	if !ok {
		return
	}
	for _, thread := range p.threadsFromResult(frame.Result, pending) {
		p.allowThread(thread)
	}
}

func (p *appServerGatewayPolicy) hasPendingThreadResponses() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.pendingThreads) > 0
}

func (p *appServerGatewayPolicy) forgetPending(id *json.RawMessage) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return
	}
	p.mu.Lock()
	delete(p.pendingThreads, key)
	p.mu.Unlock()
}

func (p *appServerGatewayPolicy) threadsFromResult(raw json.RawMessage, pending appServerGatewayPendingThreadRequest) []appServerGatewayAllowedThread {
	var threads []appServerGatewayThreadWire
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err == nil {
		appendThreadWire := func(value json.RawMessage) {
			var thread appServerGatewayThreadWire
			if len(value) > 0 && !bytes.Equal(bytes.TrimSpace(value), []byte("null")) && json.Unmarshal(value, &thread) == nil {
				threads = append(threads, thread)
			}
		}
		appendThreadWire(object["thread"])
		for _, key := range []string{"data", "threads"} {
			if value := object[key]; len(value) > 0 {
				var list []appServerGatewayThreadWire
				if err := json.Unmarshal(value, &list); err == nil {
					threads = append(threads, list...)
				}
			}
		}
	}
	if len(threads) == 0 {
		var list []appServerGatewayThreadWire
		if err := json.Unmarshal(raw, &list); err == nil {
			threads = append(threads, list...)
		}
	}

	out := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, item := range threads {
		id := firstNonEmpty(item.ID, item.ThreadID, item.SessionID)
		if strings.TrimSpace(id) == "" {
			continue
		}
		cwd := firstNonEmpty(item.CWD, item.Path, pending.cwd)
		project, ok := p.router.projectForGatewayPath(cwd)
		if !ok {
			continue
		}
		if pending.projectID != "" && project.ID != pending.projectID {
			continue
		}
		out = append(out, appServerGatewayAllowedThread{
			id:        strings.TrimSpace(id),
			cwd:       strings.TrimSpace(cwd),
			projectID: project.ID,
		})
	}
	return out
}

func (p *appServerGatewayPolicy) allowThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.projectID) == "" {
		return
	}
	thread.lastSeen = time.Now()
	p.mu.Lock()
	p.allowedThreads[thread.id] = thread
	p.mu.Unlock()
	p.router.allowGatewayThread(thread)
}

func (r *Router) allowGatewayThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.projectID) == "" {
		return
	}
	now := time.Now()
	thread.lastSeen = now
	r.gatewayThreadsMu.Lock()
	r.gatewayThreads[thread.id] = thread
	r.pruneGatewayThreadsLocked(now)
	r.gatewayThreadsMu.Unlock()
}

func (r *Router) pruneGatewayThreadsLocked(now time.Time) {
	for id, thread := range r.gatewayThreads {
		if gatewayThreadCacheExpired(thread, now) {
			delete(r.gatewayThreads, id)
		}
	}
	for len(r.gatewayThreads) > appServerGatewayThreadCacheMax {
		oldestID := ""
		oldestSeen := time.Time{}
		for id, thread := range r.gatewayThreads {
			seen := thread.lastSeen
			if seen.IsZero() {
				seen = now.Add(-appServerGatewayThreadCacheTTL - time.Nanosecond)
			}
			if oldestID == "" || seen.Before(oldestSeen) {
				oldestID = id
				oldestSeen = seen
			}
		}
		if oldestID == "" {
			return
		}
		delete(r.gatewayThreads, oldestID)
	}
}

func gatewayThreadCacheExpired(thread appServerGatewayAllowedThread, now time.Time) bool {
	if thread.lastSeen.IsZero() {
		return false
	}
	return now.Sub(thread.lastSeen) > appServerGatewayThreadCacheTTL
}

func gatewayRequestIDKey(id *json.RawMessage) string {
	if id == nil || len(bytes.TrimSpace(*id)) == 0 {
		return ""
	}
	return string(bytes.TrimSpace(*id))
}

func decodeGatewayParams(raw json.RawMessage) (map[string]any, error) {
	if len(bytes.TrimSpace(raw)) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return map[string]any{}, nil
	}
	var params map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	// 官方 app-server 当前使用命名参数；远程 gateway 不支持 positional params，避免校验策略时漏掉 cwd/sandbox 字段。
	if err := decoder.Decode(&params); err != nil {
		return nil, fmt.Errorf("JSON-RPC params 必须是对象")
	}
	return params, nil
}

func (r *Router) validateGatewayPolicyParams(method string, params map[string]any) (appServerGatewayValidatedParams, error) {
	validated := appServerGatewayValidatedParams{}
	if hasApprovalPolicyNever(params) {
		return validated, fmt.Errorf("approvalPolicy=never 不允许远程使用")
	}
	if hasDangerFullAccess(params) {
		return validated, fmt.Errorf("dangerFullAccess 不允许远程使用")
	}
	if hasNetworkAccessEnabled(params) {
		return validated, fmt.Errorf("networkAccess=true 不允许远程使用")
	}
	if cwd, ok := gatewayStringParam(params, "cwd"); ok {
		project, projectOK := r.projectForGatewayPath(cwd)
		if !projectOK {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist", method)
		}
		validated.cwd = cwd
		validated.hasCWD = true
		validated.cwdProject = project
		validated.cwdProjectOK = true
	}
	if requiresGatewayCWD(method) {
		if !validated.hasCWD {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist", method)
		}
	}
	roots, err := collectWritableRoots(params)
	if err != nil {
		return validated, err
	}
	seenRoots := map[string]struct{}{}
	for _, root := range roots {
		if root == validated.cwd && validated.cwdProjectOK {
			continue
		}
		if _, seen := seenRoots[root]; seen {
			continue
		}
		seenRoots[root] = struct{}{}
		if _, ok := r.projectForGatewayPath(root); !ok {
			return validated, fmt.Errorf("sandboxPolicy.writableRoots 必须来自 projects allowlist")
		}
	}
	inputPaths, err := collectUserInputPaths(params)
	if err != nil {
		return validated, err
	}
	for _, path := range inputPaths {
		if _, ok := r.projectForGatewayPath(path); !ok {
			return validated, fmt.Errorf("turn/start.input path 必须来自 projects allowlist")
		}
	}
	return validated, nil
}

func requiresGatewayCWD(method string) bool {
	switch method {
	case "thread/list", "thread/start", "thread/resume", "turn/start":
		return true
	default:
		return false
	}
}

func gatewayStringParam(params map[string]any, key string) (string, bool) {
	value, ok := params[key]
	if !ok {
		return "", false
	}
	text, ok := value.(string)
	return strings.TrimSpace(text), ok && strings.TrimSpace(text) != ""
}

func collectUserInputPaths(params map[string]any) ([]string, error) {
	raw, ok := params["input"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("turn/start.input 必须是数组")
	}
	paths := []string{}
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("turn/start.input item 必须是 object")
		}
		inputType, _ := gatewayStringParam(obj, "type")
		switch inputType {
		case "localImage", "skill", "mention":
			path, ok := gatewayStringParam(obj, "path")
			if !ok {
				return nil, fmt.Errorf("turn/start.input.%s.path 不能为空", inputType)
			}
			paths = append(paths, path)
		case "image":
			url, ok := gatewayStringParam(obj, "url")
			if !ok {
				return nil, fmt.Errorf("turn/start.input.image.url 不能为空")
			}
			if strings.HasPrefix(strings.ToLower(url), "file:") {
				return nil, fmt.Errorf("turn/start.input.image.url 不允许 file URL，请使用 localImage.path")
			}
		case "text":
		default:
			return nil, fmt.Errorf("turn/start.input 类型不支持：%s", inputType)
		}
	}
	return paths, nil
}

func (r *Router) projectForGatewayPath(raw string) (projects.Project, bool) {
	project, _, ok := r.projectForGatewayPathWithRealPath(raw)
	return project, ok
}

func (r *Router) projectForGatewayPathWithRealPath(raw string) (projects.Project, string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return projects.Project{}, "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return projects.Project{}, "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return projects.Project{}, "", false
	}
	project, ok := r.projects.FindByPath(realPath)
	return project, realPath, ok
}

func collectWritableRoots(value any) ([]string, error) {
	var roots []string
	if err := collectWritableRootsInto(value, &roots); err != nil {
		return nil, err
	}
	return roots, nil
}

func collectWritableRootsInto(value any, roots *[]string) error {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if strings.EqualFold(key, "writableRoots") {
				items, ok := child.([]any)
				if !ok {
					return fmt.Errorf("sandboxPolicy.writableRoots 必须是字符串数组")
				}
				for _, item := range items {
					root, ok := item.(string)
					if !ok || strings.TrimSpace(root) == "" {
						return fmt.Errorf("sandboxPolicy.writableRoots 必须是字符串数组")
					}
					*roots = append(*roots, strings.TrimSpace(root))
				}
				continue
			}
			if err := collectWritableRootsInto(child, roots); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range typed {
			if err := collectWritableRootsInto(child, roots); err != nil {
				return err
			}
		}
	}
	return nil
}

func hasApprovalPolicyNever(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if normalizePolicyValue(key) == "approvalpolicy" {
				if text, ok := child.(string); ok && strings.EqualFold(strings.TrimSpace(text), "never") {
					return true
				}
			}
			if hasApprovalPolicyNever(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasApprovalPolicyNever(child) {
				return true
			}
		}
	}
	return false
}

func hasDangerFullAccess(params map[string]any) bool {
	return hasDangerFullAccessValue(params, "")
}

func hasDangerFullAccessValue(value any, parentKey string) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			normalizedKey := normalizePolicyValue(key)
			if normalizedKey == "dangerfullaccess" {
				return true
			}
			if normalizedKey == "sandbox" || normalizedKey == "sandboxmode" || (parentKey == "sandboxpolicy" && normalizedKey == "type") {
				if text, ok := child.(string); ok && normalizePolicyValue(text) == "dangerfullaccess" {
					return true
				}
			}
			if hasDangerFullAccessValue(child, normalizedKey) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasDangerFullAccessValue(child, parentKey) {
				return true
			}
		}
	}
	return false
}

func hasNetworkAccessEnabled(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if normalizePolicyValue(key) == "networkaccess" {
				if enabled, ok := child.(bool); ok && enabled {
					return true
				}
				if text, ok := child.(string); ok && strings.EqualFold(strings.TrimSpace(text), "true") {
					return true
				}
			}
			if hasNetworkAccessEnabled(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasNetworkAccessEnabled(child) {
				return true
			}
		}
	}
	return false
}

func normalizePolicyValue(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.ReplaceAll(value, "-", "")
	value = strings.ReplaceAll(value, "_", "")
	return value
}

func writeGatewayPolicyError(conn *websocket.Conn, mu *sync.Mutex, policyErr *appServerGatewayPolicyError) bool {
	id := json.RawMessage("null")
	if policyErr.id != nil && len(*policyErr.id) > 0 {
		id = *policyErr.id
	}
	payload, err := json.Marshal(map[string]any{
		"id": id,
		"error": map[string]any{
			"code":    appServerPolicyErrorCode,
			"message": policyErr.message,
		},
	})
	if err != nil {
		return false
	}
	return writeWebSocketFrame(conn, mu, websocket.TextMessage, payload) == nil
}

func sanitizeGatewayURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "[invalid-url]"
	}
	parsed.User = nil
	parsed.RawQuery = ""
	return parsed.String()
}
