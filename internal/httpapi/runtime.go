package httpapi

import (
	"context"
	"fmt"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/codexhistory"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

type SessionRuntime interface {
	// REST API 只依赖这个稳定边界；底层可以是旧 PTY session，也可以是 Codex app-server thread。
	ListSessions(ctx context.Context, projectID string, limit int, cursor sessionPageCursor, hasCursor bool) (SessionListPage, error)
	CreateSession(ctx context.Context, req RuntimeCreateRequest) (RuntimeCreateResult, error)
	SessionDetail(ctx context.Context, id string, afterSeq int64) (SessionDetail, error)
	StopSession(ctx context.Context, id string) error
	SessionMessages(ctx context.Context, id string, before string, limit int) (codexhistory.MessagePage, error)
	SessionTrace(ctx context.Context, id string) ([]session.TraceEvent, error)
}

type SessionListPage struct {
	Sessions   []session.SessionSnapshot
	NextCursor string
	HasMore    bool
}

type RuntimeCreateRequest struct {
	Project         projects.Project
	Prompt          string
	ResumeID        string
	Title           string
	Cols            int
	Rows            int
	ClientMessageID string
}

type RuntimeCreateResult struct {
	Snapshot    session.SessionSnapshot
	LiveSession *session.Session
}

type SessionDetail struct {
	Snapshot     session.SessionSnapshot
	RecentOutput string
	LastSeq      int64
}

type PTYSessionRuntime struct {
	registry *projects.Registry
	manager  *session.Manager
}

func NewPTYSessionRuntime(registry *projects.Registry, manager *session.Manager) *PTYSessionRuntime {
	return &PTYSessionRuntime{registry: registry, manager: manager}
}

func (r *PTYSessionRuntime) ListSessions(ctx context.Context, projectID string, limit int, cursor sessionPageCursor, hasCursor bool) (SessionListPage, error) {
	list := r.manager.ListUnsorted()
	activeLimit := limit
	if activeLimit > 0 {
		activeLimit++
	}
	out := activeSessionSnapshotWindow(list, projectID, cursor, hasCursor, activeLimit)
	historyLimit := limit
	if historyLimit > 0 {
		historyLimit++
	}
	historyCursor := codexhistory.PageCursor{}
	if hasCursor {
		historyCursor = codexhistory.PageCursor{ID: cursor.ID, UpdatedAtMS: cursor.UpdatedAtMS}
	}
	// PTY fallback 同时合并当前运行中的 session 和 Codex 历史索引，保持迁移前的列表语义。
	out = append(out, codexhistory.LoadPage(r.registry, list, projectID, historyLimit, historyCursor)...)
	page, nextCursor, hasMore := paginateSessions(out, cursor, hasCursor, limit)
	return SessionListPage{Sessions: page, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (r *PTYSessionRuntime) CreateSession(ctx context.Context, req RuntimeCreateRequest) (RuntimeCreateResult, error) {
	s, err := r.manager.Create(session.CreateRequest{
		Project:         req.Project,
		Prompt:          req.Prompt,
		ResumeID:        req.ResumeID,
		Title:           req.Title,
		Cols:            req.Cols,
		Rows:            req.Rows,
		ClientMessageID: req.ClientMessageID,
	})
	if err != nil {
		return RuntimeCreateResult{}, err
	}
	return RuntimeCreateResult{Snapshot: s.Snapshot(), LiveSession: s}, nil
}

func (r *PTYSessionRuntime) SessionDetail(ctx context.Context, id string, afterSeq int64) (SessionDetail, error) {
	s, ok := r.manager.Get(id)
	if !ok {
		return SessionDetail{}, fmt.Errorf("session 不存在")
	}
	output := s.OutputSince(afterSeq)
	return SessionDetail{Snapshot: s.Snapshot(), RecentOutput: output.Data, LastSeq: output.LastSeq}, nil
}

func (r *PTYSessionRuntime) StopSession(ctx context.Context, id string) error {
	return r.manager.Stop(id)
}

func (r *PTYSessionRuntime) SessionMessages(ctx context.Context, id string, before string, limit int) (codexhistory.MessagePage, error) {
	var active *session.Session
	if s, ok := r.manager.Get(id); ok {
		active = s
	}
	threadID := historyThreadIDForSession(r.registry, id, active)
	if threadID == "" {
		return emptyMessagePage(), nil
	}
	page, err := codexhistory.MessagesPageWithLimit(threadID, before, limit)
	if err != nil {
		// 历史 rollout 可能被 Codex 清理或还未落盘；列表详情不应因为缺历史文件而中断。
		return emptyMessagePage(), nil
	}
	if active != nil {
		page.Messages = annotateHistoryMessagesWithSubmittedClientIDs(page.Messages, active.SubmittedMessages())
	}
	if page.Messages == nil {
		page.Messages = []codexhistory.Message{}
	}
	return page, nil
}

func (r *PTYSessionRuntime) SessionTrace(ctx context.Context, id string) ([]session.TraceEvent, error) {
	s, ok := r.manager.Get(id)
	if !ok {
		return nil, fmt.Errorf("session 不存在")
	}
	return s.TraceEvents(), nil
}

func emptyMessagePage() codexhistory.MessagePage {
	return codexhistory.MessagePage{Messages: []codexhistory.Message{}}
}
