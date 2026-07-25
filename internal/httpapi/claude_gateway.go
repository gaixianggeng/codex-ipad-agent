package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
)

const claudeBridgePolicyErrorCode = -32081
const claudeBridgeProbeCacheTTL = 5 * time.Second

// Transport-level handshake with the resident bridge. Mirrors ATTACH_METHOD /
// ATTACHED_METHOD in bridges/claude/crates/bridge-core/src/server.rs.
const claudeBridgeAttachMethod = "_alleycat/attach"
const claudeBridgeAttachedMethod = "_alleycat/attached"

// claudeBridgeSeqField is the top-level stamp the bridge puts on every
// outbound frame so a reconnect can resume from a known point.
const claudeBridgeSeqField = "_alleycat_seq"

// claudeBridgeServerRequestReplayMethod is the notification a bridge sends on
// attach listing the server requests still waiting on the user.
const claudeBridgeServerRequestReplayMethod = "serverRequest/replay"

// claudeBridgeFrameSeq reads the replay sequence number off an upstream frame.
func claudeBridgeFrameSeq(payload []byte) (uint64, bool) {
	if !bytes.Contains(payload, []byte(`"`+claudeBridgeSeqField+`"`)) {
		return 0, false
	}
	var frame struct {
		Seq *uint64 `json:"_alleycat_seq"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil || frame.Seq == nil {
		return 0, false
	}
	return *frame.Seq, true
}

type appServerBridgeProbe struct {
	Status    string
	Path      string
	Version   string
	Healthy   bool
	Error     string
	CheckedAt time.Time
}

func (r *Router) refreshClaudeBridgeProbe(_ bool) appServerBridgeProbe {
	probe := appServerBridgeProbe{
		Status:    "disabled",
		CheckedAt: time.Now().UTC(),
	}
	if !r.cfg.Claude.Enabled {
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	bin := strings.TrimSpace(r.cfg.Claude.BridgeBin)
	if bin == "" {
		probe.Status = "invalid"
		probe.Error = "claude.bridge_bin 未配置"
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	path, ok := resolveCommandPath(bin)
	if !ok {
		probe.Status = "missing_command"
		probe.Path = bin
		probe.Error = "找不到 Claude bridge，可配置绝对路径"
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	probe.Path = path
	// 版本门禁是协议安全边界，不能因为 cheap probe 跳过；--version 对兼容 bridge 是无副作用快速调用。
	probe.Version = probeClaudeBridgeVersion(path, r.cfg.Claude.Args, r.cfg.Claude.Env)
	if probe.Version == "" {
		probe.Status = "missing_version"
		probe.Error = claudebridge.UpgradeMessage("")
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	if !claudebridge.IsSupported(probe.Version) {
		probe.Status = "unsupported_version"
		probe.Error = claudebridge.UpgradeMessage(probe.Version)
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	probe.Status = "ready"
	probe.Healthy = true
	r.setClaudeBridgeProbe(probe)
	return probe
}

func (r *Router) setClaudeBridgeProbe(probe appServerBridgeProbe) {
	r.claudeMu.Lock()
	r.claudeProbe = probe
	r.claudeMu.Unlock()
}

func (r *Router) claudeBridgeProbe() appServerBridgeProbe {
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	if r.claudeProbe.CheckedAt.IsZero() {
		return appServerBridgeProbe{Status: "unknown"}
	}
	return r.claudeProbe
}

func (r *Router) refreshClaudeBridgeProbeIfStale() {
	if !r.cfg.Claude.Enabled {
		return
	}
	r.claudeMu.Lock()
	checkedAt := r.claudeProbe.CheckedAt
	r.claudeMu.Unlock()
	if checkedAt.IsZero() || time.Since(checkedAt) >= claudeBridgeProbeCacheTTL {
		r.refreshClaudeBridgeProbe(false)
	}
}

func resolveCommandPath(command string) (string, bool) {
	command = strings.TrimSpace(command)
	if command == "" {
		return "", false
	}
	if filepath.IsAbs(command) || strings.ContainsAny(command, `/\`) {
		info, err := os.Stat(command)
		if err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
			return command, false
		}
		return command, true
	}
	path, err := exec.LookPath(command)
	if err != nil {
		return command, false
	}
	return path, true
}

func probeClaudeBridgeVersion(path string, args []string, env map[string]string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, append(args, "--version")...)
	cmd.Env = buildClaudeBridgeEnv(env)
	output, err := cmd.Output()
	if err != nil {
		return ""
	}
	version, ok := claudebridge.ParseVersion(string(bytes.TrimSpace(output)))
	if !ok {
		return ""
	}
	return version
}

func (r *Router) appServerClaudeGatewayWS(w http.ResponseWriter, req *http.Request) {
	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("claude gateway ws upgrade failed err=%v", err)
		return
	}
	defer client.Close()

	if !r.cfg.Claude.Enabled {
		writeGatewayRuntimeError(client, "CLAUDE_DISABLED", "Claude Code runtime 未启用")
		return
	}
	// 直连 WS 可能不经过 config 接口；握手前按 TTL 重探，避免复用启动时的旧 probe 状态。
	r.refreshClaudeBridgeProbeIfStale()
	probe := r.claudeBridgeProbe()
	if !probe.Healthy {
		code := "CLAUDE_BRIDGE_UNAVAILABLE"
		switch probe.Status {
		case "missing_version":
			code = "CLAUDE_BRIDGE_VERSION_UNKNOWN"
		case "unsupported_version":
			code = "CLAUDE_BRIDGE_VERSION_UNSUPPORTED"
		}
		writeGatewayRuntimeErrorWithData(client, code, firstNonEmpty(probe.Error, "Claude bridge 不可用"), map[string]any{
			"bridgeStatus":   probe.Status,
			"bridgeVersion":  probe.Version,
			"minimumVersion": claudebridge.MinimumVersion,
			"fix":            claudebridge.InstallHint,
		})
		return
	}
	if !r.acquireClaudeBridgeSlot() {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_LIMIT_EXCEEDED", "Claude bridge 并发数已达上限，请稍后重试")
		return
	}
	defer r.releaseClaudeBridgeSlot()

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	bin := firstNonEmpty(probe.Path, strings.TrimSpace(r.cfg.Claude.BridgeBin))
	start := time.Now()
	if _, err := r.claudeBridge.ensure(bin, r.cfg.Claude.Args, r.cfg.Claude.Env); err != nil {
		log.Printf("claude bridge ensure failed err=%v", err)
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_START_FAILED", "启动 Claude bridge 失败")
		return
	}
	upstream, err := r.claudeBridge.dial()
	if err != nil {
		log.Printf("claude bridge dial failed err=%v", err)
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_UNAVAILABLE", "连接 Claude bridge 失败")
		return
	}
	defer upstream.Close()

	// The bridge outlives this connection, so a client that names a session
	// resumes the one it had; an unnamed client gets an isolated session and
	// today's semantics.
	sessionKey := claudeGatewaySessionKey(req)
	reader := bufio.NewReaderSize(upstream, 64*1024)
	var upstreamWriteMu sync.Mutex
	if sessionKey != "" {
		if err := r.attachClaudeBridgeSession(reader, upstream, &upstreamWriteMu, sessionKey); err != nil {
			log.Printf("claude bridge attach failed session=%s err=%v", sanitizeGatewayDiagnostic(sessionKey), err)
			writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_UNAVAILABLE", "连接 Claude bridge 会话失败")
			return
		}
	}

	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, "claude:"+filepath.Base(bin), time.Since(start))
	done := make(chan string, 3)
	var clientWriteMu sync.Mutex
	configureGatewayReadConn(client)
	policy := &appServerGatewayPolicy{
		router:                r,
		runtimeID:             "claude",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	defer policy.close()

	go func() {
		done <- copyClientFramesToClaudeBridge(client, upstream, &clientWriteMu, &upstreamWriteMu, policy, monitor)
	}()
	go func() {
		done <- copyClaudeBridgeFrames(ctx, reader, client, &clientWriteMu, policy, monitor, r.claudeBridge, sessionKey)
	}()
	go func() {
		pingClientGateway(ctx, client, &clientWriteMu)
		done <- "ping_failed_or_context_done"
	}()

	reason := <-done
	cancel()
	_ = upstream.Close()
	_ = client.Close()
	if monitor != nil {
		monitor.finish(reason)
	}
}

// claudeGatewaySessionKey reads the client's resumable-session name.
//
// `session` names it outright. Absent that, the thread the client opened is
// the right resume unit: a thread is what the user thinks of as "the task
// still running", and it is what they expect to find alive after the phone
// drops off the network. Clients that send neither keep the pre-resident
// behaviour: a fresh bridge session per connection, with nothing replayed.
func claudeGatewaySessionKey(req *http.Request) string {
	query := req.URL.Query()
	if raw := strings.TrimSpace(query.Get("session")); raw != "" {
		return sanitizedClaudeSessionKey(raw)
	}
	return sanitizedClaudeSessionKey(strings.TrimSpace(query.Get("thread_id")))
}

// sanitizedClaudeSessionKey drops anything that is not a short, plain
// identifier. The key is client-chosen and travels into the bridge's session
// registry and back out into logs, so it must carry no framing or control
// characters. Rejecting degrades to an unnamed session rather than failing the
// connection.
func sanitizedClaudeSessionKey(key string) string {
	if key == "" || len(key) > 128 {
		return ""
	}
	for _, c := range key {
		isSafe := c == '-' || c == '_' ||
			(c >= '0' && c <= '9') ||
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z')
		if !isSafe {
			return ""
		}
	}
	return key
}

// attachClaudeBridgeSession performs the socket handshake that binds this
// connection to a named bridge session, resuming from the last sequence number
// we managed to deliver to a client.
func (r *Router) attachClaudeBridgeSession(reader *bufio.Reader, upstream io.Writer, mu *sync.Mutex, sessionKey string) error {
	params := map[string]any{"sessionKey": sessionKey}
	cursor, hadCursor := r.claudeBridge.resumeCursor(sessionKey)
	if hadCursor {
		params["lastSeen"] = cursor
	}
	preamble, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  claudeBridgeAttachMethod,
		"params":  params,
	})
	if err != nil {
		return err
	}
	if err := writeStdioBridgeCompactedFrame(upstream, mu, preamble); err != nil {
		return err
	}
	line, oversize, err := readBridgeStdoutLine(reader, int(appServerGatewayReadLimit))
	if oversize {
		return errors.New("Claude bridge attach 应答超出大小上限")
	}
	if err != nil && len(bytes.TrimSpace(line)) == 0 {
		return fmt.Errorf("读取 Claude bridge attach 应答失败：%w", err)
	}
	var ack struct {
		Method string `json:"method"`
		Params struct {
			Kind       string `json:"kind"`
			CurrentSeq uint64 `json:"currentSeq"`
			FloorSeq   uint64 `json:"floorSeq"`
		} `json:"params"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(line), &ack); err != nil {
		return fmt.Errorf("解析 Claude bridge attach 应答失败：%w", err)
	}
	if ack.Method != claudeBridgeAttachedMethod {
		return fmt.Errorf("Claude bridge attach 应答方法异常：%s", sanitizeGatewayDiagnostic(ack.Method))
	}
	if ack.Params.Kind == "driftReload" {
		// The turn ran on past what the replay ring holds. Nothing is replayed,
		// so the client only sees events from here on and has to rehydrate the
		// thread itself — which it already does on every reconnect.
		log.Printf("claude bridge session drifted past replay window session=%s floor=%d",
			sanitizeGatewayDiagnostic(sessionKey), ack.Params.FloorSeq)
	}
	// Only "resumed" means the bridge is still counting in the sequence our
	// cursor came from. Anything else is a renumbered session, and keeping the
	// old cursor is worse than having none: the replay ring answers a cursor
	// above its current sequence with an empty slice and no error, so the next
	// attach would report "resumed" while silently skipping everything the new
	// session had produced.
	if hadCursor && (ack.Params.Kind != "resumed" || ack.Params.CurrentSeq < cursor) {
		log.Printf("claude bridge session renumbered; dropping resume cursor session=%s kind=%s cursor=%d current=%d",
			sanitizeGatewayDiagnostic(sessionKey), sanitizeGatewayDiagnostic(ack.Params.Kind), cursor, ack.Params.CurrentSeq)
		r.claudeBridge.forgetCursor(sessionKey)
	}
	return nil
}

func (r *Router) acquireClaudeBridgeSlot() bool {
	limit := r.cfg.Claude.MaxConcurrentBridges
	if limit <= 0 {
		limit = 3
	}
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	if r.activeClaudeBridge >= limit {
		return false
	}
	r.activeClaudeBridge++
	return true
}

func (r *Router) releaseClaudeBridgeSlot() {
	r.claudeMu.Lock()
	if r.activeClaudeBridge > 0 {
		r.activeClaudeBridge--
	}
	r.claudeMu.Unlock()
}

func copyClientFramesToClaudeBridge(client *websocket.Conn, stdin io.Writer, clientWriteMu *sync.Mutex, stdinWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return gatewayCloseReason("client_read", err)
		}
		policyStart := time.Now()
		forwardPayload, policyErr := policy.validateClientFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			if monitor != nil {
				monitor.recordPolicyError("client_to_upstream", len(payload), policyDuration)
			}
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return "client_policy_error_write_failed"
			}
			continue
		}
		compacted, err := compactJSONLine(forwardPayload)
		if err != nil {
			return gatewayCloseReason("bridge_stdin_encode", err)
		}
		requestID := ""
		if monitor != nil {
			requestID = monitor.beginRPCRequest(compacted, len(compacted))
		}
		writeStart := time.Now()
		err = writeStdioBridgeCompactedFrame(stdin, stdinWriteMu, compacted)
		if err != nil {
			if monitor != nil {
				monitor.cancelRPCRequest(requestID)
			}
			return gatewayCloseReason("bridge_stdin_write", err)
		}
		if monitor != nil {
			monitor.recordForward("client_to_upstream", len(payload), len(compacted), policyDuration, time.Since(writeStart), compacted)
		}
	}
}

func copyClaudeBridgeFrames(ctx context.Context, reader *bufio.Reader, client *websocket.Conn, clientWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor, supervisor *claudeBridgeSupervisor, sessionKey string) string {
	// bufio.Scanner 在单行超过 buffer 上限时会以 ErrTooLong 终止扫描，等于让一条超大
	// 帧（例如一次超大文件 Read 的 base64 输出）撕掉整条 WS 连接、触发客户端重连循环。
	// 改用有界逐行读取：超过上限的单帧只丢弃并记诊断，连接继续存活。上限沿用客户端
	// WS 读上限——比它更大的帧客户端本就无法接收，丢弃是唯一安全选择。
	maxLine := int(appServerGatewayReadLimit)
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		default:
		}
		line, oversize, err := readBridgeStdoutLine(reader, maxLine)
		if oversize {
			log.Printf("claude bridge stdout line exceeded %d bytes; dropping frame to keep connection alive", maxLine)
			if monitor != nil {
				monitor.recordDropped("upstream_to_client", maxLine, 0)
			}
		} else if payload := bytes.TrimSpace(line); len(payload) > 0 {
			if reason, ok := forwardClaudeBridgeFrame(payload, client, clientWriteMu, policy, monitor); ok {
				return reason
			}
			// Only frames we finished handling advance the cursor, so whatever
			// died in flight when the socket broke gets replayed. Frames the
			// policy dropped count as handled: replaying them would only get
			// them dropped again.
			if sessionKey != "" {
				if seq, ok := claudeBridgeFrameSeq(payload); ok {
					supervisor.noteDelivered(sessionKey, seq)
				}
			}
		}
		if err != nil {
			if err == io.EOF {
				return "bridge_stdout_closed"
			}
			log.Printf("claude bridge stdout read error err=%v", err)
			return gatewayCloseReason("bridge_stdout_read", err)
		}
	}
}

// forwardClaudeBridgeFrame runs one upstream frame through the policy layer and
// forwards it to the client. It returns a non-empty close reason + true only
// when the caller must tear the connection down (client write failed).
func forwardClaudeBridgeFrame(payload []byte, client *websocket.Conn, clientWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) (string, bool) {
	policyStart := time.Now()
	forwardPayload, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	policyDuration := time.Since(policyStart)
	if policyErr != nil {
		if monitor != nil {
			monitor.recordPolicyError("upstream_to_client", len(payload), policyDuration)
		}
		if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
			return "upstream_policy_error_write_failed", true
		}
		return "", false
	}
	if !forward {
		if monitor != nil {
			monitor.recordDropped("upstream_to_client", len(payload), policyDuration)
		}
		return "", false
	}
	frame := append([]byte(nil), forwardPayload...)
	if rewritten, ok := rewriteClaudeModelListResponse(policy, frame); ok {
		frame = rewritten
	}
	writeStart := time.Now()
	if err := writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, frame); err != nil {
		return gatewayCloseReason("client_write", err), true
	}
	if monitor != nil {
		monitor.recordForward("upstream_to_client", len(payload), len(frame), policyDuration, time.Since(writeStart), frame)
	}
	return "", false
}

// readBridgeStdoutLine reads one '\n'-terminated line from reader while bounding
// resident memory to ~max bytes. When a single line exceeds max the excess is
// drained to the newline and the function returns oversize=true with a nil line,
// so the caller can drop that one frame without tearing down the connection.
// The trailing io.EOF (line without a final newline) is returned alongside any
// bytes read so the caller can process the last frame before closing.
func readBridgeStdoutLine(reader *bufio.Reader, max int) ([]byte, bool, error) {
	var buf []byte
	oversize := false
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(chunk) > 0 && !oversize {
			buf = append(buf, chunk...)
			if max > 0 && len(buf) > max {
				oversize = true
				buf = nil // release; an oversized frame is never forwarded
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if oversize {
			return nil, true, err
		}
		return buf, false, err
	}
}

func writeStdioBridgeFrame(stdin io.Writer, mu *sync.Mutex, payload []byte) ([]byte, error) {
	compacted, err := compactJSONLine(payload)
	if err != nil {
		return nil, err
	}
	if err := writeStdioBridgeCompactedFrame(stdin, mu, compacted); err != nil {
		return nil, err
	}
	return compacted, nil
}

func writeStdioBridgeCompactedFrame(stdin io.Writer, mu *sync.Mutex, compacted []byte) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	if _, err := stdin.Write(compacted); err != nil {
		return err
	}
	if _, err := stdin.Write([]byte("\n")); err != nil {
		return err
	}
	return nil
}

func compactJSONLine(payload []byte) ([]byte, error) {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 无效")
	}
	compacted, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 重编码失败：%w", err)
	}
	return compacted, nil
}

func rewriteClaudeModelListResponse(policy *appServerGatewayPolicy, payload []byte) ([]byte, bool) {
	if policy == nil {
		return nil, false
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil || !gatewayFrameIsResponse(&frame) {
		return nil, false
	}
	pending, ok := policy.consumePendingClientRequest(frame.ID)
	if !ok || pending.method != "model/list" || len(frame.Error) > 0 {
		return nil, false
	}
	var object map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&object); err != nil {
		return nil, false
	}
	object["result"] = map[string]any{
		"data":       claudeCurrentModelList(),
		"nextCursor": nil,
	}
	delete(object, "error")
	rewritten, err := json.Marshal(object)
	if err != nil {
		return nil, false
	}
	return rewritten, true
}

func claudeCurrentModelList() []map[string]any {
	// Claude CLI 的具体模型 ID 会比产品命名更频繁变化；这里用 CLI alias 作为真正发送的
	// model，避免新名字尚未进入本机 metadata 时触发 fallback warning。为兼容尚不识别 `fable`
	// 短 alias 的旧 CLI，Fable 使用官方完整 ID；展示名仍表达当前推荐代际。
	return []map[string]any{
		claudeModelOption(
			"claude-fable-5",
			"Claude Fable 5",
			"Anthropic's most capable generally available model for the hardest, longest-running agentic work.",
			false,
			"high",
		),
		claudeModelOption(
			"opus",
			"Claude Opus 5",
			"Alias resolved by the Claude CLI to the latest available Opus model; best for complex agentic coding and deep reasoning.",
			true,
			"high",
		),
		claudeModelOption(
			"sonnet",
			"Claude Sonnet 5",
			"Alias resolved by the Claude CLI to the latest available Sonnet model; default balanced model for everyday coding work.",
			false,
			"high",
		),
		claudeModelOption(
			"haiku",
			"Claude Haiku 4.5",
			"Alias resolved by the Claude CLI to the latest available Haiku model; fastest choice for quick edits and small tasks.",
			false,
			"minimal",
		),
	}
}

func claudeModelOption(modelID string, displayName string, description string, isDefault bool, defaultEffort string) map[string]any {
	return map[string]any{
		"id":                        modelID,
		"model":                     modelID,
		"displayName":               displayName,
		"description":               description,
		"hidden":                    false,
		"supportedReasoningEfforts": claudeReasoningEffortOptions(),
		"defaultReasoningEffort":    defaultEffort,
		"inputModalities":           []string{"text", "image"},
		"supportsPersonality":       false,
		"additionalSpeedTiers":      []any{},
		"serviceTiers":              []map[string]string{{"id": "standard", "name": "Standard", "description": "Default bridge service tier"}},
		"isDefault":                 isDefault,
	}
}

func claudeReasoningEffortOptions() []map[string]string {
	return []map[string]string{
		{"reasoningEffort": "minimal", "description": "Lowest latency, no extended thinking"},
		{"reasoningEffort": "low", "description": "Brief reasoning"},
		{"reasoningEffort": "medium", "description": "Default depth of reasoning"},
		{"reasoningEffort": "high", "description": "Maximum reasoning effort"},
	}
}

func pingClientGateway(ctx context.Context, client *websocket.Conn, clientWriteMu *sync.Mutex) {
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
		}
	}
}

func buildClaudeBridgeEnv(extra map[string]string) []string {
	keys := []string{"HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM"}
	out := make([]string, 0, len(keys)+len(extra))
	seen := map[string]struct{}{}
	for _, key := range keys {
		value := os.Getenv(key)
		if value == "" {
			continue
		}
		out = append(out, key+"="+value)
		seen[key] = struct{}{}
	}
	for key, value := range extra {
		key = strings.TrimSpace(key)
		if key == "" || strings.Contains(key, "=") {
			continue
		}
		if _, ok := seen[key]; ok {
			for i, item := range out {
				if strings.HasPrefix(item, key+"=") {
					out[i] = key + "=" + value
					break
				}
			}
			continue
		}
		out = append(out, key+"="+value)
	}
	// 远程 Claude 通道永不允许绕过权限；即使本机配置误设为 true，也在进程边界强制覆盖。
	const bypassKey = "CLAUDE_BRIDGE_BYPASS_PERMISSIONS"
	foundBypass := false
	for index, item := range out {
		if strings.HasPrefix(item, bypassKey+"=") {
			out[index] = bypassKey + "=false"
			foundBypass = true
			break
		}
	}
	if !foundBypass {
		out = append(out, bypassKey+"=false")
	}
	return out
}

func captureClaudeBridgeStderr(stderr io.Reader) {
	scanner := bufio.NewScanner(stderr)
	for scanner.Scan() {
		line := sanitizeGatewayDiagnostic(scanner.Text())
		if line == "" {
			continue
		}
		log.Printf("claude bridge stderr: %s", line)
	}
	if err := scanner.Err(); err != nil {
		log.Printf("claude bridge stderr scanner error err=%v", err)
	}
}

func sanitizeGatewayDiagnostic(value string) string {
	line := strings.TrimSpace(value)
	if line == "" {
		return ""
	}
	lower := strings.ToLower(line)
	for _, marker := range []string{"token", "secret", "password", "api_key", "apikey", "authorization", "bearer"} {
		if strings.Contains(lower, marker) {
			return "<redacted sensitive diagnostic>"
		}
	}
	return trimRelayString(line, 300)
}

func writeGatewayRuntimeError(conn *websocket.Conn, code string, message string) {
	writeGatewayRuntimeErrorWithData(conn, code, message, nil)
}

func writeGatewayRuntimeErrorWithData(conn *websocket.Conn, code string, message string, details map[string]any) {
	data := map[string]any{"code": code}
	for key, value := range details {
		if value == nil || value == "" {
			continue
		}
		data[key] = value
	}
	payload := map[string]any{
		"jsonrpc": "2.0",
		"id":      nil,
		"error": map[string]any{
			"code":    claudeBridgePolicyErrorCode,
			"message": code + ": " + message,
			"data":    data,
		},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	_ = conn.WriteMessage(websocket.TextMessage, raw)
}

func configureGatewayCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func terminateGatewayProcessGroup(cmd *exec.Cmd, signal syscall.Signal) {
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}
	if err := syscall.Kill(-pid, signal); err != nil && err != syscall.ESRCH {
		_ = syscall.Kill(pid, signal)
	}
}

func gatewayProcessID(cmd *exec.Cmd) int {
	if cmd == nil || cmd.Process == nil {
		return 0
	}
	return cmd.Process.Pid
}
