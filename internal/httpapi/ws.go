package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"
)

type wsMessage struct {
	Type    string          `json:"type"`
	Data    string          `json:"data,omitempty"`
	Cols    int             `json:"cols,omitempty"`
	Rows    int             `json:"rows,omitempty"`
	Session any             `json:"session,omitempty"`
	Exit    any             `json:"exit,omitempty"`
	Error   string          `json:"error,omitempty"`
	Raw     json.RawMessage `json:"-"`
}

func (r *Router) sessionWS(w http.ResponseWriter, req *http.Request, id string) {
	s, ok := r.sessions.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "session 不存在")
		return
	}
	output, detach, err := s.Attach()
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

	var writeMu sync.Mutex
	send := func(msg wsMessage) bool {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		return conn.WriteJSON(msg) == nil
	}

	send(wsMessage{Type: "session", Session: s.Snapshot()})
	if recent := s.RecentOutput(); recent != "" {
		if !send(wsMessage{Type: "output", Data: recent}) {
			return
		}
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
			if !send(wsMessage{Type: "output", Data: string(chunk)}) {
				return
			}
		case <-s.Done():
			send(wsMessage{Type: "exit", Exit: s.ExitResult()})
			return
		case <-done:
			log.Printf("ws disconnected session=%s", id)
			return
		case <-req.Context().Done():
			return
		}
	}
}
