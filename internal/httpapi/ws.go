package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	sessionpkg "github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

const rolloutAssistantForwardLimit = 200
const rolloutAssistantForwardInterval = 500 * time.Millisecond
const rolloutAssistantForwardTimeout = 45 * time.Second

type wsMessage struct {
	Type            string          `json:"type"`
	Data            string          `json:"data,omitempty"`
	Seq             int64           `json:"seq,omitempty"`
	SessionID       string          `json:"session_id,omitempty"`
	TurnID          string          `json:"turn_id,omitempty"`
	ItemID          string          `json:"item_id,omitempty"`
	MessageID       string          `json:"message_id,omitempty"`
	ApprovalID      string          `json:"approval_id,omitempty"`
	Decision        string          `json:"decision,omitempty"`
	ClientMessageID string          `json:"client_message_id,omitempty"`
	Revision        int64           `json:"revision,omitempty"`
	Cols            int             `json:"cols,omitempty"`
	Rows            int             `json:"rows,omitempty"`
	Session         any             `json:"session,omitempty"`
	Row             any             `json:"row,omitempty"`
	Message         *agentMessage   `json:"message,omitempty"`
	Delta           any             `json:"delta,omitempty"`
	Log             any             `json:"log,omitempty"`
	Diff            any             `json:"diff,omitempty"`
	Approval        any             `json:"approval,omitempty"`
	Context         any             `json:"context,omitempty"`
	Usage           any             `json:"usage,omitempty"`
	RateLimit       any             `json:"rate_limit,omitempty"`
	Warning         any             `json:"warning,omitempty"`
	Status          string          `json:"status,omitempty"`
	Exit            any             `json:"exit,omitempty"`
	Error           string          `json:"error,omitempty"`
	Raw             json.RawMessage `json:"-"`
}

func (r *Router) sessionWS(w http.ResponseWriter, req *http.Request, id string) {
	s, ok := r.sessions.Get(id)
	if ok {
		r.ptySessionWS(w, req, id, s)
		return
	}
	if appRuntime, ok := r.runtime.(*CodexAppServerRuntime); ok {
		r.appServerSessionWS(w, req, id, appRuntime)
		return
	}
	writeError(w, http.StatusNotFound, "session 不存在")
}

func (r *Router) ptySessionWS(w http.ResponseWriter, req *http.Request, id string, s *sessionpkg.Session) {
	afterSeq := positiveSeq(req.URL.Query().Get("after_seq"))
	output, initialReplay, initialSnapshot, detach, err := s.AttachAfter(afterSeq)
	if err != nil {
		log.Printf("ws attach failed session=%s err=%v", id, err)
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	defer detach()

	conn, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("ws upgrade failed session=%s err=%v", id, err)
		return
	}
	defer conn.Close()
	log.Printf("ws connected session=%s", id)
	s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_connected", AfterSeq: afterSeq})

	var writeMu sync.Mutex
	send := func(msg wsMessage) bool {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		return conn.WriteJSON(msg) == nil
	}
	sendOutput := func(data string, seq int64) bool {
		if !send(wsMessage{Type: "output", Data: data, Seq: seq, SessionID: id}) {
			return false
		}
		// log_delta 是给新客户端的结构化日志通道；output 继续保留，兼容现有 Web/测试客户端。
		return send(wsMessage{Type: "log_delta", Data: data, Seq: seq, SessionID: id})
	}
	submittedMessages := s.SubmittedMessages()
	structuredMessages := newStructuredMessageTracker()
	markBefore := time.Now().UTC()
	if firstSubmittedAt, ok := earliestSubmittedMessageTime(submittedMessages); ok {
		markBefore = firstSubmittedAt
	}
	structuredMessages.markExisting(r.projects, id, s, markBefore)

	send(wsMessage{Type: "session", Session: s.Snapshot()})
	for _, chunk := range initialReplay {
		if !sendOutput(string(chunk.Data), chunk.Seq) {
			return
		}
	}
	if len(initialReplay) > 0 {
		s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_replay_sent", AfterSeq: afterSeq, Chunks: len(initialReplay)})
	}
	if initialSnapshot != nil && initialSnapshot.Data != "" {
		if !sendOutput(initialSnapshot.Data, initialSnapshot.LastSeq) {
			return
		}
		s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_snapshot_sent", AfterSeq: afterSeq, Seq: initialSnapshot.LastSeq, Bytes: len(initialSnapshot.Data)})
	}

	done := make(chan struct{})
	rolloutForwarder := newRolloutAssistantForwarder(r.projects, id, s, structuredMessages, done, send)
	forwardSubmittedRolloutAssistantMessages(submittedMessages, rolloutForwarder)
	go func() {
		defer close(done)
		for {
			var msg wsMessage
			if err := conn.ReadJSON(&msg); err != nil {
				return
			}
			switch msg.Type {
			case "input":
				log.Printf("ws input session=%s bytes=%d", id, len(msg.Data))
				s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_input", Bytes: len(msg.Data)})
				if err := s.Write(msg.Data); err != nil {
					log.Printf("ws input failed session=%s err=%v", id, err)
					send(wsMessage{Type: "error", Error: err.Error()})
					continue
				}
				clientMessageID := strings.TrimSpace(msg.ClientMessageID)
				if clientMessageID == "" {
					continue
				}
				if message, ok := userMessageConfirmation(id, clientMessageID, msg.Data, time.Now().UTC()); ok {
					recordSubmittedUserMessage(s, message)
					send(wsMessage{
						Type:            "message_completed",
						SessionID:       id,
						ClientMessageID: clientMessageID,
						Message:         &message,
					})
					rolloutForwarder.Request(message.CreatedAt)
				}
			case "resize":
				if err := s.Resize(msg.Cols, msg.Rows); err != nil {
					log.Printf("ws resize failed session=%s cols=%d rows=%d err=%v", id, msg.Cols, msg.Rows, err)
					send(wsMessage{Type: "error", Error: err.Error()})
				}
			case "signal":
				if msg.Data == "ctrl_c" {
					log.Printf("ws signal session=%s data=ctrl_c", id)
					_ = s.Write("\x03")
				}
			case "ping":
				send(wsMessage{Type: "pong"})
			default:
				send(wsMessage{Type: "error", Error: "未知 WebSocket 消息类型"})
			}
		}
	}()

	for {
		select {
		case chunk := <-output:
			if !sendOutput(string(chunk.Data), chunk.Seq) {
				return
			}
		case <-s.Done():
			s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_exit_sent"})
			send(wsMessage{Type: "exit", Exit: s.ExitResult()})
			return
		case <-done:
			log.Printf("ws disconnected session=%s", id)
			s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_disconnected"})
			return
		case <-req.Context().Done():
			s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_context_done"})
			return
		}
	}
}

func (r *Router) appServerSessionWS(w http.ResponseWriter, req *http.Request, id string, runtime *CodexAppServerRuntime) {
	detail, err := runtime.SessionDetail(req.Context(), id, 0)
	if err != nil {
		writeError(w, http.StatusNotFound, "session 不存在")
		return
	}
	events, detach, err := runtime.Subscribe(req.Context(), id)
	if err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	defer detach()

	conn, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("app-server ws upgrade failed session=%s err=%v", id, err)
		return
	}
	defer conn.Close()
	log.Printf("app-server ws connected session=%s", id)
	runtime.appendTrace(id, sessionpkg.TraceEvent{Type: "app_server_ws_connected"})

	var writeMu sync.Mutex
	send := func(msg wsMessage) bool {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		return conn.WriteJSON(msg) == nil
	}
	send(wsMessage{Type: "session", SessionID: id, Session: detail.Snapshot})

	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			var msg wsMessage
			if err := conn.ReadJSON(&msg); err != nil {
				return
			}
			switch msg.Type {
			case "input":
				log.Printf("app-server ws input session=%s bytes=%d", id, len(msg.Data))
				result, err := runtime.StartTurnForSession(req.Context(), id, msg.Data, msg.ClientMessageID)
				if err != nil {
					log.Printf("app-server ws input failed session=%s err=%v", id, err)
					send(wsMessage{Type: "error", Error: err.Error()})
					continue
				}
				if result.Message != nil {
					seq := runtime.nextEventSeq(id)
					send(wsMessage{
						Type:            "message_completed",
						SessionID:       id,
						TurnID:          result.TurnID,
						ClientMessageID: msg.ClientMessageID,
						Seq:             seq,
						Revision:        seq,
						Message:         result.Message,
					})
				}
			case "signal":
				if msg.Data == "ctrl_c" {
					_ = runtime.StopSession(req.Context(), id)
				}
			case "approval_decision":
				approvalID := firstNonEmpty(msg.ApprovalID, msg.ItemID, msg.MessageID)
				if err := runtime.ResolveApproval(id, approvalID, msg.Decision, msg.Data); err != nil {
					send(wsMessage{Type: "error", Error: err.Error()})
					continue
				}
				send(wsMessage{Type: "session_status", SessionID: id, Status: "running"})
			case "resize":
				send(wsMessage{
					Type:      "warning",
					SessionID: id,
					Warning:   map[string]any{"message": "app-server runtime 暂不需要终端 resize"},
				})
			case "ping":
				send(wsMessage{Type: "pong"})
			default:
				send(wsMessage{Type: "error", Error: "未知 WebSocket 消息类型"})
			}
		}
	}()

	for {
		select {
		case event := <-events:
			if !send(runtimeEventToWSMessage(event)) {
				return
			}
		case <-done:
			log.Printf("app-server ws disconnected session=%s", id)
			runtime.appendTrace(id, sessionpkg.TraceEvent{Type: "app_server_ws_disconnected"})
			return
		case <-req.Context().Done():
			runtime.appendTrace(id, sessionpkg.TraceEvent{Type: "app_server_ws_context_done"})
			return
		}
	}
}

func runtimeEventToWSMessage(event runtimeStreamEvent) wsMessage {
	msg := wsMessage{
		Type:      event.Type,
		Data:      event.Data,
		Seq:       event.Seq,
		SessionID: event.SessionID,
		TurnID:    event.TurnID,
		ItemID:    event.ItemID,
		MessageID: event.MessageID,
		Revision:  event.Revision,
		Status:    event.Status,
		Row:       event.Row,
		Usage:     event.Usage,
		RateLimit: event.RateLimit,
		Context:   event.Context,
		Message:   event.Message,
		Error:     event.Error,
	}
	switch event.Type {
	case "assistant_delta":
		msg.Delta = map[string]any{"text": event.Data, "role": "assistant", "kind": "message"}
	case "log_delta":
		msg.Log = map[string]any{"text": event.Data}
	case "diff_updated":
		msg.Diff = event.Diff
	case "approval_request":
		msg.Approval = event.Approval
	case "warning":
		msg.Warning = event.Warning
	}
	return msg
}

type structuredMessageTracker struct {
	sync.Mutex
	seen map[string]bool
}

func newStructuredMessageTracker() *structuredMessageTracker {
	return &structuredMessageTracker{seen: map[string]bool{}}
}

type rolloutAssistantForwarder struct {
	registry  *projects.Registry
	sessionID string
	session   *sessionpkg.Session
	tracker   *structuredMessageTracker
	done      <-chan struct{}
	send      func(wsMessage) bool

	mu       sync.Mutex
	after    time.Time
	deadline time.Time
	running  bool
	wake     chan struct{}
}

func newRolloutAssistantForwarder(
	registry *projects.Registry,
	sessionID string,
	s *sessionpkg.Session,
	tracker *structuredMessageTracker,
	done <-chan struct{},
	send func(wsMessage) bool,
) *rolloutAssistantForwarder {
	return &rolloutAssistantForwarder{
		registry:  registry,
		sessionID: sessionID,
		session:   s,
		tracker:   tracker,
		done:      done,
		send:      send,
		wake:      make(chan struct{}, 1),
	}
}

func (f *rolloutAssistantForwarder) Request(after time.Time) {
	if after.IsZero() {
		return
	}
	now := time.Now()
	deadline := now.Add(rolloutAssistantForwardTimeout)

	f.mu.Lock()
	// 多条提交共享一个连接级 poller。扫描水位保留最早提交点，避免后来的输入
	// 把尚未转发的 assistant 消息跳过去；deadline 则按最新输入向后延长。
	if f.after.IsZero() || after.Before(f.after) {
		f.after = after
	}
	if deadline.After(f.deadline) {
		f.deadline = deadline
	}
	if f.running {
		f.signalLocked()
		f.mu.Unlock()
		return
	}
	f.running = true
	f.mu.Unlock()

	f.session.RecordTrace(sessionpkg.TraceEvent{Type: "rollout_assistant_poll_started"})
	go f.run()
}

func (f *rolloutAssistantForwarder) signalLocked() {
	select {
	case f.wake <- struct{}{}:
	default:
	}
}

func (f *rolloutAssistantForwarder) run() {
	ticker := time.NewTicker(rolloutAssistantForwardInterval)
	defer ticker.Stop()

	for {
		f.mu.Lock()
		after := f.after
		deadline := f.deadline
		f.mu.Unlock()

		if !forwardRolloutAssistantMessagesOnce(f.registry, f.sessionID, f.session, after, f.tracker, f.send) {
			f.stop()
			return
		}

		wait := time.Until(deadline)
		if wait <= 0 {
			f.mu.Lock()
			if !f.deadline.After(deadline) {
				f.running = false
				f.mu.Unlock()
				return
			}
			f.mu.Unlock()
			continue
		}

		timer := time.NewTimer(wait)
		select {
		case <-ticker.C:
			stopTimer(timer)
		case <-timer.C:
		case <-f.wake:
			stopTimer(timer)
		case <-f.done:
			stopTimer(timer)
			f.stop()
			return
		}
	}
}

func (f *rolloutAssistantForwarder) stop() {
	f.mu.Lock()
	f.running = false
	f.mu.Unlock()
}

func stopTimer(timer *time.Timer) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
}

func earliestSubmittedMessageTime(messages []sessionpkg.SubmittedMessage) (time.Time, bool) {
	var earliest time.Time
	for _, message := range messages {
		if message.CreatedAt.IsZero() {
			continue
		}
		if earliest.IsZero() || message.CreatedAt.Before(earliest) {
			earliest = message.CreatedAt
		}
	}
	return earliest, !earliest.IsZero()
}

func (t *structuredMessageTracker) markExisting(registry *projects.Registry, sessionID string, s *sessionpkg.Session, before time.Time) {
	messages, err := recentCodexMessagesForSession(registry, sessionID, s, rolloutAssistantForwardLimit)
	if err != nil {
		return
	}
	t.Lock()
	defer t.Unlock()
	for _, message := range messages {
		if !before.IsZero() && !message.CreatedAt.IsZero() && message.CreatedAt.After(before) {
			continue
		}
		if message.ID != "" {
			t.seen[message.ID] = true
		}
	}
}

func (t *structuredMessageTracker) markIfNew(id string) bool {
	if id == "" {
		return false
	}
	t.Lock()
	defer t.Unlock()
	if t.seen[id] {
		return false
	}
	t.seen[id] = true
	return true
}

func forwardSubmittedRolloutAssistantMessages(
	submitted []sessionpkg.SubmittedMessage,
	forwarder *rolloutAssistantForwarder,
) {
	after, ok := earliestSubmittedMessageTime(submitted)
	if !ok {
		return
	}
	// 首条 prompt 通过 HTTP 创建会话时，用户确认已经在 POST 响应里返回；
	// WS 连接建立后仍要从这条提交点开始补 assistant 的结构化消息，避免 iOS 只能看到 PTY 日志。
	forwarder.Request(after)
}

func forwardRolloutAssistantMessagesOnce(
	registry *projects.Registry,
	sessionID string,
	s *sessionpkg.Session,
	after time.Time,
	tracker *structuredMessageTracker,
	send func(wsMessage) bool,
) bool {
	messages, err := recentCodexMessagesForSession(registry, sessionID, s, rolloutAssistantForwardLimit)
	if err != nil {
		s.RecordTrace(sessionpkg.TraceEvent{Type: "rollout_assistant_poll_failed", Reason: err.Error()})
		return true
	}
	minCreatedAt := after.Add(-2 * time.Second)
	for _, message := range messages {
		if message.Role != "assistant" || message.CreatedAt.Before(minCreatedAt) {
			continue
		}
		if !tracker.markIfNew(message.ID) {
			continue
		}
		agentMessage, ok := agentMessageFromHistory(sessionID, message)
		if !ok {
			continue
		}
		if !send(wsMessage{Type: "message_completed", SessionID: sessionID, Message: &agentMessage}) {
			return false
		}
		s.RecordTrace(sessionpkg.TraceEvent{Type: "rollout_assistant_forwarded", Sent: 1})
	}
	return true
}

func positiveSeq(raw string) int64 {
	if raw == "" {
		return 0
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n <= 0 {
		return 0
	}
	return n
}
