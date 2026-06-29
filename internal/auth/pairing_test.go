package auth

import (
	"strings"
	"testing"
	"time"
)

func TestPairingTicketValidatesSignatureAndExpiry(t *testing.T) {
	now := time.Date(2026, 6, 29, 10, 0, 0, 0, time.UTC)
	ticket := NewPairingTicket("http://100.64.0.1:8787", "0123456789abcdef0123456789abcdef", now, now.Add(10*time.Minute))

	if err := ValidatePairingTicket("0123456789abcdef0123456789abcdef", ticket, now.Add(time.Minute)); err != nil {
		t.Fatalf("合法配对票据应通过校验：%v", err)
	}

	ticket.Endpoint = "http://100.64.0.2:8787"
	if err := ValidatePairingTicket("0123456789abcdef0123456789abcdef", ticket, now.Add(time.Minute)); err == nil || !strings.Contains(err.Error(), "签名") {
		t.Fatalf("篡改 endpoint 应导致签名失败，got=%v", err)
	}
}

func TestPairingTicketRejectsExpiredTicket(t *testing.T) {
	now := time.Date(2026, 6, 29, 10, 0, 0, 0, time.UTC)
	ticket := NewPairingTicket("http://100.64.0.1:8787", "0123456789abcdef0123456789abcdef", now.Add(-20*time.Minute), now.Add(-10*time.Minute))

	if err := ValidatePairingTicket("0123456789abcdef0123456789abcdef", ticket, now); err == nil || !strings.Contains(err.Error(), "过期") {
		t.Fatalf("过期配对票据应被拒绝，got=%v", err)
	}
}
