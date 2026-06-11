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
	"reflect"
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

var (
	appServerGatewayReadLimit               int64 = 64 << 20
	appServerGatewayPongWait                      = 60 * time.Second
	appServerGatewayPingPeriod                    = 45 * time.Second
	appServerGatewayPendingThreadTTL              = 30 * time.Second
	appServerGatewayPendingThreadMax              = 128
	appServerGatewayPendingServerRequestTTL       = 24 * time.Hour
	appServerGatewayPendingServerRequestMax       = 256
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

	pendingThreads        map[string]appServerGatewayPendingThreadRequest
	pendingServerRequests map[string]appServerGatewayPendingServerRequest
	allowedThreads        map[string]appServerGatewayAllowedThread
}

type appServerGatewayPendingThreadRequest struct {
	method    string
	cwd       string
	scopeID   string
	createdAt time.Time
}

type appServerGatewayPendingServerRequest struct {
	method    string
	createdAt time.Time
}

type appServerGatewayValidatedParams struct {
	cwd        string
	hasCWD     bool
	cwdScope   gatewayScope
	cwdScopeOK bool
}

// gatewayScope 描述一个 cwd 的授权来源。命中 projects allowlist 时是项目作用域，
// 线程可以在同一项目内的子目录间工作；命中 browse_roots 时是“精确目录”作用域，
// scope id 取该目录 canonical 路径的 workspace hash，线程被绑定到这一个目录，
// turn/start 切到 sibling 目录（如 ~/finance → ~/Documents）会因 scope id 不同被拒。
type gatewayScope struct {
	id       string
	realPath string
	project  projects.Project
	browse   bool
}

type appServerGatewayAllowedThread struct {
	id       string
	cwd      string
	scopeID  string
	lastSeen time.Time
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
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{}, 3)
	var clientWriteMu sync.Mutex
	var upstreamWriteMu sync.Mutex
	configureGatewayReadConn(client)
	configureGatewayReadConn(upstream)
	policy := &appServerGatewayPolicy{
		router:                r,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}

	go func() {
		defer func() { done <- struct{}{} }()
		r.copyClientFramesToAppServer(client, upstream, &clientWriteMu, &upstreamWriteMu, policy)
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		copyWebSocketFrames(ctx, upstream, client, &upstreamWriteMu, &clientWriteMu, policy)
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		pingGatewayConnections(ctx, client, upstream, &clientWriteMu, &upstreamWriteMu)
	}()

	<-done
	cancel()
	_ = client.Close()
	_ = upstream.Close()
}

func configureGatewayReadConn(conn *websocket.Conn) {
	conn.SetReadLimit(appServerGatewayReadLimit)
	_ = conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	})
}

func pingGatewayConnections(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex) {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			deadline := time.Now().Add(appServerGatewayWriteWindow)
			if err := writeWebSocketControl(client, clientWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return
			}
			if err := writeWebSocketControl(upstream, upstreamWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return
			}
		}
	}
}

func (r *Router) copyClientFramesToAppServer(client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex, policy *appServerGatewayPolicy) {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return
		}
		forwardPayload, policyErr := policy.validateClientFrame(messageType, payload)
		if policyErr != nil {
			// 非法请求只回 JSON-RPC error，不把高危帧送到 app-server。
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return
			}
			continue
		}
		if err := writeWebSocketFrame(upstream, upstreamWriteMu, messageType, forwardPayload); err != nil {
			return
		}
	}
}

func copyWebSocketFrames(ctx context.Context, from *websocket.Conn, to *websocket.Conn, fromWriteMu *sync.Mutex, toWriteMu *sync.Mutex, policy *appServerGatewayPolicy) {
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
		forward, policyErr := policy.observeUpstreamFrame(messageType, payload)
		if policyErr != nil {
			if !writeGatewayPolicyError(from, fromWriteMu, policyErr) {
				return
			}
			continue
		}
		if !forward {
			continue
		}
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

func writeWebSocketControl(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte, deadline time.Time) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	return conn.WriteControl(messageType, payload, deadline)
}

func (p *appServerGatewayPolicy) validateClientFrame(messageType int, payload []byte) ([]byte, *appServerGatewayPolicyError) {
	if messageType != websocket.TextMessage {
		return nil, &appServerGatewayPolicyError{message: "app-server gateway 只允许 JSON text frame"}
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return nil, &appServerGatewayPolicyError{message: "JSON-RPC frame 无效"}
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" {
		if frame.ID != nil && (len(frame.Result) > 0 || len(frame.Error) > 0) {
			rewritten, err := p.validateClientResponse(payload, &frame)
			if err != nil {
				return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
			}
			return rewritten, nil
		}
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "JSON-RPC frame 缺少 method"}
	}
	if method != "initialized" && frame.ID == nil {
		return nil, &appServerGatewayPolicyError{message: "app-server request 必须包含 id"}
	}
	if _, ok := appServerAllowedMethods[method]; !ok {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "app-server method 不允许：" + method}
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	validated, err := p.router.validateGatewayPolicyParams(method, params)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if err := p.validateThreadCapability(&frame, method, params, validated); err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	rewritten, err := rewriteGatewaySafeDefaults(payload, method, params, validated)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	return rewritten, nil
}

func (p *appServerGatewayPolicy) validateThreadCapability(frame *appServerGatewayFrame, method string, params map[string]any, validated appServerGatewayValidatedParams) error {
	cwd := validated.cwd
	scope := validated.cwdScope
	scopeOK := validated.cwdScopeOK

	switch method {
	case "thread/list", "thread/start":
		if err := p.rememberPendingThreadResponse(frame.ID, method, cwd, scope.id); err != nil {
			return err
		}
	case "thread/resume":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if !scopeOK || scope.id != thread.scopeID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的工作区", method)
		}
		if err := p.rememberPendingThreadResponse(frame.ID, method, cwd, scope.id); err != nil {
			return err
		}
	case "thread/read":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if err := p.rememberPendingThreadResponse(frame.ID, method, "", ""); err != nil {
			return err
		}
	case "turn/start":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		// 项目作用域：同项目内目录都可用；browse 作用域：scope id 是 canonical cwd 的
		// hash，等价于精确目录绑定，不允许切到允许根下的 sibling 目录。
		if !scopeOK || scope.id != thread.scopeID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的工作区", method)
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

func (p *appServerGatewayPolicy) validateClientResponse(payload []byte, frame *appServerGatewayFrame) ([]byte, error) {
	if frame.ID == nil {
		return nil, fmt.Errorf("JSON-RPC response 缺少 id")
	}
	request, ok := p.consumePendingServerRequest(frame.ID)
	if !ok {
		return nil, fmt.Errorf("JSON-RPC response id 未由 app-server 发起")
	}
	if len(frame.Error) > 0 {
		return payload, nil
	}
	if len(frame.Result) == 0 {
		return nil, fmt.Errorf("JSON-RPC response 缺少 result")
	}
	if !isPermissionsApprovalMethod(request.method) {
		return payload, nil
	}
	return rewriteGatewayPermissionsApprovalResponse(payload)
}

func rewriteGatewayPermissionsApprovalResponse(payload []byte) ([]byte, error) {
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("JSON-RPC response 无效")
	}
	frame["result"] = map[string]any{
		"permissions":      map[string]any{},
		"scope":            "turn",
		"strictAutoReview": true,
	}
	delete(frame, "error")
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("重写 permissions approval response 失败：%w", err)
	}
	return rewritten, nil
}

func isPermissionsApprovalMethod(method string) bool {
	return strings.Contains(strings.ToLower(strings.TrimSpace(method)), "permissions/requestapproval")
}

func rewriteGatewaySafeDefaults(payload []byte, method string, params map[string]any, validated appServerGatewayValidatedParams) ([]byte, error) {
	var sanitized map[string]any
	switch method {
	case "initialize":
		sanitized = sanitizedGatewayInitializeParams(params)
	case "initialized", "model/list", "account/rateLimits/read":
		sanitized = map[string]any{}
	case "thread/list":
		sanitized = copyGatewayParams(params, "cwd", "limit", "cursor")
	case "thread/read":
		sanitized = copyGatewayParams(params, "threadId", "includeTurns")
	case "thread/start", "thread/resume":
		sanitized = sanitizedGatewayThreadParams(method, params)
	case "turn/start":
		sanitized = sanitizedGatewayTurnParams(params, validated.cwd)
	case "turn/interrupt":
		sanitized = copyGatewayParams(params, "threadId", "turnId")
	default:
		return payload, nil
	}
	if reflect.DeepEqual(params, sanitized) {
		return payload, nil
	}
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 无效")
	}
	frame["params"] = sanitized
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("重写 app-server 安全参数失败：%w", err)
	}
	return rewritten, nil
}

func sanitizedGatewayInitializeParams(params map[string]any) map[string]any {
	safe := map[string]any{}
	if clientInfo, ok := params["clientInfo"].(map[string]any); ok {
		sanitizedClientInfo := copyGatewayStringParams(clientInfo, "name", "title", "version")
		if len(sanitizedClientInfo) > 0 {
			safe["clientInfo"] = sanitizedClientInfo
		}
	}
	if capabilities, ok := params["capabilities"].(map[string]any); ok {
		sanitizedCapabilities := copyGatewayBoolParams(capabilities, "experimentalApi", "requestAttestation")
		if len(sanitizedCapabilities) > 0 {
			safe["capabilities"] = sanitizedCapabilities
		}
	}
	return safe
}

func sanitizedGatewayThreadParams(method string, params map[string]any) map[string]any {
	safe := copyGatewayParams(params, "cwd", "model", "modelProvider", "serviceTier", "personality")
	if method == "thread/resume" {
		copyGatewayParam(safe, params, "threadId")
		safe["excludeTurns"] = true
	}
	safe["approvalPolicy"] = "on-request"
	safe["approvalsReviewer"] = "user"
	safe["sandbox"] = sanitizedGatewayThreadSandbox(params)
	return safe
}

func sanitizedGatewayThreadSandbox(params map[string]any) string {
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "readonly" {
		return "read-only"
	}
	return "workspace-write"
}

func sanitizedGatewayTurnParams(params map[string]any, cwd string) map[string]any {
	safe := copyGatewayParams(params, "threadId", "cwd", "input", "clientUserMessageId", "model", "serviceTier", "effort", "summary", "personality")
	safe["approvalPolicy"] = "on-request"
	safe["approvalsReviewer"] = "user"
	safe["sandboxPolicy"] = sanitizedGatewaySandboxPolicy(params["sandboxPolicy"], cwd)
	return safe
}

func sanitizedGatewaySandboxPolicy(raw any, cwd string) map[string]any {
	sandbox, _ := raw.(map[string]any)
	sandboxType, _ := gatewayStringParam(sandbox, "type")
	normalizedType := normalizePolicyValue(sandboxType)
	if normalizedType == "readonly" {
		return map[string]any{
			"type":          "readOnly",
			"networkAccess": false,
		}
	}
	return map[string]any{
		"type":          "workspaceWrite",
		"writableRoots": []any{cwd},
		"networkAccess": false,
	}
}

func copyGatewayParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		copyGatewayParam(copied, params, key)
	}
	return copied
}

func copyGatewayParam(dst map[string]any, src map[string]any, key string) {
	if value, ok := src[key]; ok {
		dst[key] = value
	}
}

func copyGatewayStringParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		if value, ok := params[key].(string); ok {
			copied[key] = value
		}
	}
	return copied
}

func copyGatewayBoolParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		if value, ok := params[key].(bool); ok {
			copied[key] = value
		}
	}
	return copied
}

func (p *appServerGatewayPolicy) rememberPendingThreadResponse(id *json.RawMessage, method string, cwd string, scopeID string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingThreadsLocked(now)
	if _, exists := p.pendingThreads[key]; !exists && len(p.pendingThreads) >= appServerGatewayPendingThreadMax {
		return fmt.Errorf("gateway pending thread 请求过多")
	}
	p.pendingThreads[key] = appServerGatewayPendingThreadRequest{method: method, cwd: cwd, scopeID: scopeID, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) prunePendingThreadsLocked(now time.Time) {
	for id, pending := range p.pendingThreads {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingThreadTTL {
			delete(p.pendingThreads, id)
		}
	}
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

func (p *appServerGatewayPolicy) observeUpstreamFrame(messageType int, payload []byte) (bool, *appServerGatewayPolicyError) {
	if messageType != websocket.TextMessage {
		return true, nil
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID != nil {
		if err := p.rememberPendingServerRequest(frame.ID, frame.Method); err != nil {
			return false, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
		}
		return true, nil
	}
	if !p.hasPendingThreadResponses() {
		return true, nil
	}
	if frame.ID == nil || len(frame.Result) == 0 || len(frame.Error) > 0 {
		p.forgetPending(frame.ID)
		return true, nil
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return true, nil
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	if ok {
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	if !ok {
		return true, nil
	}
	for _, thread := range p.threadsFromResult(frame.Result, pending) {
		p.allowThread(thread)
	}
	return true, nil
}

func (p *appServerGatewayPolicy) rememberPendingServerRequest(id *json.RawMessage, method string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("app-server request 缺少 id")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingServerRequestsLocked(now)
	if p.pendingServerRequests == nil {
		p.pendingServerRequests = map[string]appServerGatewayPendingServerRequest{}
	}
	if _, exists := p.pendingServerRequests[key]; !exists && len(p.pendingServerRequests) >= appServerGatewayPendingServerRequestMax {
		return fmt.Errorf("gateway pending server request 过多")
	}
	p.pendingServerRequests[key] = appServerGatewayPendingServerRequest{method: method, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) consumePendingServerRequest(id *json.RawMessage) (appServerGatewayPendingServerRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingServerRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingServerRequestsLocked(time.Now())
	request, ok := p.pendingServerRequests[key]
	if ok {
		delete(p.pendingServerRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingServerRequestsLocked(now time.Time) {
	for id, pending := range p.pendingServerRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingServerRequestTTL {
			delete(p.pendingServerRequests, id)
		}
	}
}

func (p *appServerGatewayPolicy) hasPendingThreadResponses() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingThreadsLocked(time.Now())
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
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		if pending.scopeID != "" && scope.id != pending.scopeID {
			continue
		}
		out = append(out, appServerGatewayAllowedThread{
			id: strings.TrimSpace(id),
			// browse 作用域用 canonical 路径绑定，避免同一目录的不同写法绕过精确匹配。
			cwd:     scope.realPath,
			scopeID: scope.id,
		})
	}
	return out
}

func (p *appServerGatewayPolicy) allowThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return
	}
	thread.lastSeen = time.Now()
	p.mu.Lock()
	p.allowedThreads[thread.id] = thread
	p.mu.Unlock()
	p.router.allowGatewayThread(thread)
}

func (r *Router) allowGatewayThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
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
		scope, scopeOK := r.gatewayScopeForPath(cwd)
		if !scopeOK {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist 或 browse_roots", method)
		}
		validated.cwd = cwd
		validated.hasCWD = true
		validated.cwdScope = scope
		validated.cwdScopeOK = true
	}
	if requiresGatewayCWD(method) {
		if !validated.hasCWD {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist 或 browse_roots", method)
		}
	}
	roots, err := collectWritableRoots(params)
	if err != nil {
		return validated, err
	}
	seenRoots := map[string]struct{}{}
	for _, root := range roots {
		if root == validated.cwd && validated.cwdScopeOK {
			continue
		}
		if _, seen := seenRoots[root]; seen {
			continue
		}
		seenRoots[root] = struct{}{}
		// writableRoots 不随 browse_roots 放宽：browse workspace 的可写范围只有 cwd 本身
		//（上面 root == cwd 已放行），其余仍要求命中项目 allowlist。
		if _, ok := r.projectForGatewayPath(root); !ok {
			return validated, fmt.Errorf("sandboxPolicy.writableRoots 必须来自 projects allowlist")
		}
	}
	inputPaths, err := collectUserInputPaths(params)
	if err != nil {
		return validated, err
	}
	for _, path := range inputPaths {
		if _, ok := r.projectForGatewayPath(path); ok {
			continue
		}
		// browse workspace 的结构化输入（图片/mention/skill）允许引用绑定目录内的文件，
		// 但不允许引用允许根下的 sibling 目录，保持和 cwd 一样的精确边界。
		if validated.cwdScopeOK && validated.cwdScope.browse && gatewayScopeContainsPath(validated.cwdScope, path) {
			continue
		}
		return validated, fmt.Errorf("turn/start.input path 必须来自 projects allowlist")
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

// gatewayScopeForPath 把路径解析成授权作用域：优先命中 projects allowlist（项目作用域），
// 否则若在 browse_roots 内则得到精确目录作用域；两者都不命中即未授权。
func (r *Router) gatewayScopeForPath(raw string) (gatewayScope, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return gatewayScope{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return gatewayScope{}, false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return gatewayScope{}, false
	}
	if project, ok := r.projects.FindByPath(realPath); ok {
		return gatewayScope{id: project.ID, realPath: realPath, project: project}, true
	}
	if r.realPathInBrowseRoots(realPath) {
		return gatewayScope{id: workspaceIDForRealPath(realPath), realPath: realPath, browse: true}, true
	}
	return gatewayScope{}, false
}

// realPathInBrowseRoots 期望传入已 EvalSymlinks 的路径；browse root 自身每次惰性
// canonical 化，配置后新建的目录也能即时生效。
func (r *Router) realPathInBrowseRoots(realPath string) bool {
	for _, root := range r.cfg.BrowseRoots {
		value := strings.TrimSpace(root)
		if value == "" {
			continue
		}
		abs, err := filepath.Abs(value)
		if err != nil {
			continue
		}
		realRoot, err := filepath.EvalSymlinks(abs)
		if err != nil {
			continue
		}
		if realPathWithin(realRoot, realPath) {
			return true
		}
	}
	return false
}

func gatewayScopeContainsPath(scope gatewayScope, raw string) bool {
	path := strings.TrimSpace(raw)
	if path == "" {
		return false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return false
	}
	return realPathWithin(scope.realPath, realPath)
}

func realPathWithin(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)))
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
