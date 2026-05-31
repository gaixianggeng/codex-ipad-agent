package codexhistory

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

type row struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	CWD         string `json:"cwd"`
	CreatedAtMS int64  `json:"created_at_ms"`
	UpdatedAtMS int64  `json:"updated_at_ms"`
}

type Message struct {
	Role      string    `json:"role"`
	Content   string    `json:"content"`
	CreatedAt time.Time `json:"created_at"`
}

func Load(registry *projects.Registry, active []*session.Session) []session.Session {
	db := filepath.Join(homeDir(), ".codex", "state_5.sqlite")
	if _, err := os.Stat(db); err != nil {
		return nil
	}
	out, err := exec.Command("sqlite3", "-json", db, "select id,title,cwd,created_at_ms,updated_at_ms from threads where archived=0 order by updated_at_ms desc limit 300").Output()
	if err != nil {
		return nil
	}
	var rows []row
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil
	}

	seen := map[string]bool{}
	for _, s := range active {
		if s.ResumeID != "" {
			seen[s.ResumeID] = true
		}
		if strings.HasPrefix(s.ID, "codex_") {
			seen[strings.TrimPrefix(s.ID, "codex_")] = true
		}
	}

	var sessions []session.Session
	for _, item := range rows {
		if item.ID == "" || seen[item.ID] {
			continue
		}
		project, ok := registry.FindByPath(item.CWD)
		if !ok {
			continue
		}
		title := strings.TrimSpace(item.Title)
		if title == "" {
			title = "Codex 历史会话"
		}
		sessions = append(sessions, session.Session{
			ID:        "codex_" + item.ID,
			ProjectID: project.ID,
			Project:   project.Name,
			Dir:       project.Path,
			Title:     trimRunes(title, 48),
			Status:    "history",
			Source:    "codex",
			ResumeID:  item.ID,
			CreatedAt: msTime(item.CreatedAtMS),
			UpdatedAt: msTime(item.UpdatedAtMS),
		})
	}
	return sessions
}

func Messages(threadID string) ([]Message, error) {
	path, err := rolloutPath(threadID)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var messages []Message
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		var item struct {
			Timestamp string          `json:"timestamp"`
			Type      string          `json:"type"`
			Payload   json.RawMessage `json:"payload"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &item); err != nil || item.Type != "event_msg" {
			continue
		}
		var event struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Phase   string `json:"phase"`
		}
		if err := json.Unmarshal(item.Payload, &event); err != nil {
			continue
		}
		role := ""
		switch event.Type {
		case "user_message":
			role = "user"
		case "agent_message":
			role = "assistant"
		default:
			continue
		}
		text := strings.TrimSpace(event.Message)
		if text == "" {
			continue
		}
		messages = append(messages, Message{Role: role, Content: text, CreatedAt: parseTime(item.Timestamp)})
	}
	return messages, scanner.Err()
}

func rolloutPath(threadID string) (string, error) {
	db := filepath.Join(homeDir(), ".codex", "state_5.sqlite")
	out, err := exec.Command("sqlite3", "-json", db, "select rollout_path from threads where id = '"+strings.ReplaceAll(threadID, "'", "''")+"' limit 1").Output()
	if err != nil {
		return "", err
	}
	var rows []struct {
		RolloutPath string `json:"rollout_path"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return "", err
	}
	if len(rows) == 0 || rows[0].RolloutPath == "" {
		return "", os.ErrNotExist
	}
	return rows[0].RolloutPath, nil
}

func homeDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		return home
	}
	return ""
}

func msTime(v int64) time.Time {
	if v <= 0 {
		return time.Now()
	}
	return time.UnixMilli(v)
}

func parseTime(raw string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Now()
	}
	return t
}

func trimRunes(s string, n int) string {
	runes := []rune(strings.Join(strings.Fields(s), " "))
	if len(runes) <= n {
		return string(runes)
	}
	return string(runes[:n]) + "..."
}
