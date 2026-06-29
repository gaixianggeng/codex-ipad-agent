package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

type pairingClaimRequest struct {
	Endpoint  string `json:"endpoint"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
	Signature string `json:"pair_sig"`
}

type pairingClaimResponse struct {
	Endpoint string `json:"endpoint"`
	Token    string `json:"token"`
}

func (r *Router) pairingClaimHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload pairingClaimRequest
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体不是合法 JSON")
		return
	}
	ticket := auth.PairingTicket{
		Endpoint:  payload.Endpoint,
		IssuedAt:  payload.IssuedAt,
		ExpiresAt: payload.ExpiresAt,
		Signature: payload.Signature,
	}
	if err := auth.ValidatePairingTicket(r.cfg.Auth.Token, ticket, time.Now().UTC()); err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	token := strings.TrimSpace(r.cfg.Auth.Token)
	if token == "" {
		writeError(w, http.StatusServiceUnavailable, "auth.token 未配置")
		return
	}
	writeJSON(w, http.StatusOK, pairingClaimResponse{
		Endpoint: strings.TrimSpace(payload.Endpoint),
		Token:    token,
	})
}
