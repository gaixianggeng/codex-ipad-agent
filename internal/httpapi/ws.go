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

type wsMessage struct {
	Type            string          `json:"type"`
	Data            string          `json:"data,omitempty"`
	Seq             int64           `json:"seq,omitempty"`
	SessionID       string          `json:"session_id,omitempty"`
	ClientMessageID string          `json:"client_message_id,omitempty"`
	Cols            int             `json:"cols,omitempty"`
	Rows            int             `json:"rows,omitempty"`
	Session         any             `json:"session,omitempty"`
	Message         *agentMessage   `json:"message,omitempty"`
	Exit            any             `json:"exit,omitempty"`
	Error           string          `json:"error,omitempty"`
	Raw             json.RawMessage `json:"-"`
}

func (r *Router) sessionWS(w http.ResponseWriter, req *http.Request, id string) {
	s, ok := r.sessions.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "session 不存在")
		return
	}
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
	firstSubmittedAt, hasSubmitted := earliestSubmittedMessageTime(submittedMessages)
	markBefore := time.Now().UTC()
	if hasSubmitted {
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
	if hasSubmitted {
		// 只有结构化客户端（曾带 client_message_id 提交过）才起连接级 poller：
		// 从最早提交点补 assistant 结构化消息，覆盖“首条 prompt 经 HTTP 创建、WS attach
		// 后才补消息”。旧 Web/终端客户端不消费 message_completed，不启动以免无谓轮询。
		rolloutForwarder.Request(firstSubmittedAt)
	}
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

	mu      sync.Mutex
	after   time.Time
	running bool
	wake    chan struct{}
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
	f.mu.Lock()
	// 多条提交共享一个连接级 poller。扫描水位保留最早提交点，避免后来的输入
	// 把尚未转发的 assistant 消息跳过去。
	if f.after.IsZero() || after.Before(f.after) {
		f.after = after
	}
	if f.running {
		// 新输入唤醒一次立即轮询，缩短首条 assistant 的到达延迟。
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

// run 在整个 WS 连接生命周期内按固定间隔轮询 rollout，直到连接关闭（done）。
// 故意不设“距上次输入 45s”这类截止时间：长回复（turn 超过 45s）或 rollout 落盘较晚时，
// 旧逻辑会在 poller 已退出后才写入 assistant 消息，导致对话框永远收不到这条回复，
// 而 PTY 日志仍在实时显示——正是“日志有、对话没有”的根因。
func (f *rolloutAssistantForwarder) run() {
	ticker := time.NewTicker(rolloutAssistantForwardInterval)
	defer ticker.Stop()

	for {
		f.mu.Lock()
		after := f.after
		f.mu.Unlock()

		if !forwardRolloutAssistantMessagesOnce(f.registry, f.sessionID, f.session, after, f.tracker, f.send) {
			f.stop()
			return
		}

		select {
		case <-ticker.C:
		case <-f.wake:
		case <-f.done:
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
