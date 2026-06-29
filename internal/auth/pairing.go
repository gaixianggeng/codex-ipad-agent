package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"strings"
	"time"
)

type PairingTicket struct {
	Endpoint  string `json:"endpoint"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
	Signature string `json:"pair_sig"`
}

func NewPairingTicket(endpoint string, secret string, issuedAt time.Time, expiresAt time.Time) PairingTicket {
	ticket := PairingTicket{
		Endpoint:  strings.TrimSpace(endpoint),
		IssuedAt:  issuedAt.UTC().Format(time.RFC3339),
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
	}
	ticket.Signature = SignPairingTicket(secret, ticket.Endpoint, ticket.IssuedAt, ticket.ExpiresAt)
	return ticket
}

func SignPairingTicket(secret string, endpoint string, issuedAt string, expiresAt string) string {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(secret)))
	mac.Write([]byte(strings.TrimSpace(endpoint)))
	mac.Write([]byte{'\n'})
	mac.Write([]byte(strings.TrimSpace(issuedAt)))
	mac.Write([]byte{'\n'})
	mac.Write([]byte(strings.TrimSpace(expiresAt)))
	return hex.EncodeToString(mac.Sum(nil))
}

func ValidatePairingTicket(secret string, ticket PairingTicket, now time.Time) error {
	secret = strings.TrimSpace(secret)
	endpoint := strings.TrimSpace(ticket.Endpoint)
	issuedAt := strings.TrimSpace(ticket.IssuedAt)
	expiresAt := strings.TrimSpace(ticket.ExpiresAt)
	signature := strings.TrimSpace(ticket.Signature)
	if secret == "" {
		return fmt.Errorf("配对不可用：auth.token 未配置")
	}
	if endpoint == "" || issuedAt == "" || expiresAt == "" || signature == "" {
		return fmt.Errorf("配对票据缺少必要字段")
	}
	expiry, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil {
		return fmt.Errorf("配对票据 expires_at 无效")
	}
	if !now.Before(expiry) {
		return fmt.Errorf("配对二维码已过期")
	}
	issued, err := time.Parse(time.RFC3339, issuedAt)
	if err != nil {
		return fmt.Errorf("配对票据 issued_at 无效")
	}
	if issued.After(now.Add(2 * time.Minute)) {
		return fmt.Errorf("配对票据 issued_at 超出允许范围")
	}
	expected := SignPairingTicket(secret, endpoint, issuedAt, expiresAt)
	if subtle.ConstantTimeCompare([]byte(signature), []byte(expected)) != 1 {
		return fmt.Errorf("配对票据签名无效")
	}
	return nil
}
