package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	sessionpkg "github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

type wsMessage struct {
	Type      string          `json:"type"`
	Data      string          `json:"data,omitempty"`
	Seq       int64           `json:"seq,omitempty"`
	SessionID string          `json:"session_id,omitempty"`
	Cols      int             `json:"cols,omitempty"`
	Rows      int             `json:"rows,omitempty"`
	Session   any             `json:"session,omitempty"`
	Exit      any             `json:"exit,omitempty"`
	Error     string          `json:"error,omitempty"`
	Raw       json.RawMessage `json:"-"`
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

	send(wsMessage{Type: "session", Session: s.Snapshot()})
	for _, chunk := range initialReplay {
		if !send(wsMessage{Type: "output", Data: string(chunk.Data), Seq: chunk.Seq, SessionID: id}) {
			return
		}
	}
	if len(initialReplay) > 0 {
		s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_replay_sent", AfterSeq: afterSeq, Chunks: len(initialReplay)})
	}
	if initialSnapshot != nil && initialSnapshot.Data != "" {
		if !send(wsMessage{Type: "output", Data: initialSnapshot.Data, Seq: initialSnapshot.LastSeq, SessionID: id}) {
			return
		}
		s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_snapshot_sent", AfterSeq: afterSeq, Seq: initialSnapshot.LastSeq, Bytes: len(initialSnapshot.Data)})
	}

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
				log.Printf("ws input session=%s bytes=%d", id, len(msg.Data))
				s.RecordTrace(sessionpkg.TraceEvent{Type: "ws_input", Bytes: len(msg.Data)})
				if err := s.Write(msg.Data); err != nil {
					log.Printf("ws input failed session=%s err=%v", id, err)
					send(wsMessage{Type: "error", Error: err.Error()})
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
			if !send(wsMessage{Type: "output", Data: string(chunk.Data), Seq: chunk.Seq, SessionID: id}) {
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
