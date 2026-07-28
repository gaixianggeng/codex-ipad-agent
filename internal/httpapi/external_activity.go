package httpapi

import (
	"log"
	"net/http"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
)

type externalActivitySource interface {
	Snapshot() ([]codexhistory.ExternalActivity, error)
}

type externalActivityResponse struct {
	Activities []codexhistory.ExternalActivity `json:"activities"`
	ScannedAt  time.Time                       `json:"scanned_at"`
}

func (r *Router) externalActivityHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if r.externalActivity == nil {
		writeJSON(w, http.StatusOK, externalActivityResponse{
			Activities: []codexhistory.ExternalActivity{},
			ScannedAt:  time.Now().UTC(),
		})
		return
	}
	activities, err := r.externalActivity.Snapshot()
	if err != nil {
		// 错误响应不包含 SQLite/rollout 路径；详细路径只留在本机 agentd 日志。
		log.Printf("external activity snapshot failed: %v", err)
		http.Error(w, "external activity unavailable", http.StatusServiceUnavailable)
		return
	}
	if activities == nil {
		activities = []codexhistory.ExternalActivity{}
	}
	writeJSON(w, http.StatusOK, externalActivityResponse{
		Activities: activities,
		ScannedAt:  time.Now().UTC(),
	})
}
