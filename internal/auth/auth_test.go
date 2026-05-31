package auth

import (
	"net/http"
	"testing"
)

func TestAuthenticatorValidBearerToken(t *testing.T) {
	a := New("0123456789abcdef0123456789abcdef", false)
	req, err := http.NewRequest(http.MethodGet, "/api/projects", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer 0123456789abcdef0123456789abcdef")
	if !a.ValidRequest(req) {
		t.Fatal("期望合法 token 通过校验")
	}
}

func TestAuthenticatorRejectsWrongToken(t *testing.T) {
	a := New("0123456789abcdef0123456789abcdef", false)
	req, err := http.NewRequest(http.MethodGet, "/api/projects?token=bad-token", nil)
	if err != nil {
		t.Fatal(err)
	}
	if a.ValidRequest(req) {
		t.Fatal("期望错误 token 被拒绝")
	}
}
