package ring

import "sync"

type Buffer struct {
	mu    sync.Mutex
	limit int
	data  []byte
}

func New(limit int) *Buffer {
	if limit <= 0 {
		limit = 128 * 1024
	}
	return &Buffer{limit: limit}
}

func (b *Buffer) Write(p []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.data = append(b.data, p...)
	if len(b.data) > b.limit {
		// 只保留最近输出，避免 iPad 长时间运行后被大日志拖垮。
		b.data = append([]byte(nil), b.data[len(b.data)-b.limit:]...)
	}
}

func (b *Buffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(append([]byte(nil), b.data...))
}
