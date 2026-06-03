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

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/appserver"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
)

const (
	appServerGatewayPath        = "/api/app-server/ws"
	appServerPolicyErrorCode    = -32080
	appServerGatewayWriteWindow = 10 * time.Second
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
	CompatibilityURL   string `json:"compatibility_sessions_url"`
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

func (r *Router) appServerConfigHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, appServerConfigResponse{
		GatewayWSURL: r.appServerGatewayURL(req),
		Runtime:      r.appServerRuntimeMetadata(),
		Projects:     r.projects.List(),
		Policy: appServerPolicyMetadata{
			AllowedMethods: appServerAllowedMethodList(),
			ProjectsSource: "agentd_allowlist",
		},
	})
}

func (r *Router) appServerRuntimeMetadata() appServerRuntimeMetadata {
	upstream, _ := r.appServerUpstreamWebSocketURL()
	meta := appServerRuntimeMetadata{
		Type:               firstNonEmpty(r.cfg.Runtime.Type, "pty"),
		Transport:          firstNonEmpty(r.cfg.AppServer.Transport, "stdio"),
		Managed:            r.cfg.AppServer.Managed,
		GatewayAvailable:   upstream != "",
		UpstreamConfigured: strings.TrimSpace(r.cfg.AppServer.Listen) != "",
		CompatibilityURL:   "/api/sessions",
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

	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
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

	go func() {
		defer func() { done <- struct{}{} }()
		r.copyClientFramesToAppServer(client, upstream, &clientWriteMu)
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		copyWebSocketFrames(ctx, upstream, client, &clientWriteMu)
	}()

	<-done
	_ = client.Close()
	_ = upstream.Close()
}

func (r *Router) copyClientFramesToAppServer(client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex) {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return
		}
		if policyErr := r.validateAppServerGatewayFrame(messageType, payload); policyErr != nil {
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

func copyWebSocketFrames(ctx context.Context, from *websocket.Conn, to *websocket.Conn, toWriteMu *sync.Mutex) {
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

func (r *Router) validateAppServerGatewayFrame(messageType int, payload []byte) *appServerGatewayPolicyError {
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
	if _, ok := appServerAllowedMethods[method]; !ok {
		return &appServerGatewayPolicyError{id: frame.ID, message: "app-server method 不允许：" + method}
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if err := r.validateGatewayPolicyParams(method, params); err != nil {
		return &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	return nil
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

func (r *Router) validateGatewayPolicyParams(method string, params map[string]any) error {
	if hasApprovalPolicyNever(params) {
		return fmt.Errorf("approvalPolicy=never 不允许远程使用")
	}
	if hasDangerFullAccess(params) {
		return fmt.Errorf("dangerFullAccess 不允许远程使用")
	}
	if hasNetworkAccessEnabled(params) {
		return fmt.Errorf("networkAccess=true 不允许远程使用")
	}
	if requiresGatewayCWD(method) {
		cwd, ok := gatewayStringParam(params, "cwd")
		if !ok || !r.pathInProjectAllowlist(cwd) {
			return fmt.Errorf("%s.cwd 必须来自 projects allowlist", method)
		}
	} else if cwd, ok := gatewayStringParam(params, "cwd"); ok && !r.pathInProjectAllowlist(cwd) {
		return fmt.Errorf("%s.cwd 必须来自 projects allowlist", method)
	}
	roots, err := collectWritableRoots(params)
	if err != nil {
		return err
	}
	for _, root := range roots {
		if !r.pathInProjectAllowlist(root) {
			return fmt.Errorf("sandboxPolicy.writableRoots 必须来自 projects allowlist")
		}
	}
	return nil
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

func (r *Router) pathInProjectAllowlist(raw string) bool {
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
	_, ok := r.projects.FindByPath(realPath)
	return ok
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
			if strings.EqualFold(key, "approvalPolicy") {
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
	if sandbox, ok := gatewayValueForKey(params, "sandbox"); ok {
		if text, ok := sandbox.(string); ok && normalizePolicyValue(text) == "dangerfullaccess" {
			return true
		}
	}
	sandboxPolicy, ok := gatewayValueForKey(params, "sandboxPolicy")
	if !ok {
		return false
	}
	policy, ok := sandboxPolicy.(map[string]any)
	if !ok {
		return false
	}
	for key, child := range policy {
		if normalizePolicyValue(key) == "dangerfullaccess" {
			return true
		}
		if strings.EqualFold(key, "type") {
			if text, ok := child.(string); ok && normalizePolicyValue(text) == "dangerfullaccess" {
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
			if strings.EqualFold(key, "networkAccess") {
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

func gatewayValueForKey(values map[string]any, target string) (any, bool) {
	for key, value := range values {
		if strings.EqualFold(key, target) {
			return value, true
		}
	}
	return nil, false
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
