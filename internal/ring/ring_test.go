package ring

import "testing"

func TestBufferKeepsRecentBytes(t *testing.T) {
	b := New(5)
	b.Write([]byte("hello"))
	b.Write([]byte(" world"))
	if got := b.String(); got != "world" {
		t.Fatalf("期望保留最近输出 world，实际 %q", got)
	}
}
