package httpapi

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/protocolcontract"
)

type protocolErrorResponse struct {
	Error                         string `json:"error"`
	Code                          string `json:"code"`
	ClientProtocolRevision        int    `json:"client_protocol_revision,omitempty"`
	MinimumServerProtocolRevision int    `json:"minimum_server_protocol_revision,omitempty"`
	ServerProtocolRevision        int    `json:"server_protocol_revision"`
	MinimumClientProtocolRevision int    `json:"minimum_client_protocol_revision"`
}

// protocolCompatibilityMiddleware 允许没有协商 header 的上一版客户端按 revision 1 接入；
// 一旦任一 header 出现就要求元数据完整，避免半升级客户端被误判为兼容。
func protocolCompatibilityMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		// WebSocket 握手失败时客户端通常拿不到 JSON body，因此同一份修订窗口也写入响应 header。
		w.Header().Set(protocolcontract.ServerRevisionHeader, strconv.Itoa(protocolcontract.CurrentRevision))
		w.Header().Set(
			protocolcontract.MinimumClientRevisionHeader,
			strconv.Itoa(protocolcontract.MinimumSupportedClientRevision),
		)
		metadata, err := clientProtocolMetadata(req)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, protocolErrorResponse{
				Error:                         err.Error(),
				Code:                          "protocol_metadata_invalid",
				ServerProtocolRevision:        protocolcontract.CurrentRevision,
				MinimumClientProtocolRevision: protocolcontract.MinimumSupportedClientRevision,
			})
			return
		}
		if compatibilityErr := protocolcontract.CheckClient(metadata); compatibilityErr != nil {
			writeJSON(w, http.StatusUpgradeRequired, protocolErrorResponse{
				Error:                         compatibilityErr.Message,
				Code:                          compatibilityErr.Code,
				ClientProtocolRevision:        compatibilityErr.ClientProtocolRevision,
				MinimumServerProtocolRevision: compatibilityErr.MinimumServerProtocolRevision,
				ServerProtocolRevision:        compatibilityErr.ServerProtocolRevision,
				MinimumClientProtocolRevision: compatibilityErr.MinimumClientProtocolRevision,
			})
			return
		}
		next.ServeHTTP(w, req)
	})
}

func clientProtocolMetadata(req *http.Request) (protocolcontract.ClientMetadata, error) {
	clientRevision := strings.TrimSpace(req.Header.Get(protocolcontract.ClientRevisionHeader))
	minimumServerRevision := strings.TrimSpace(req.Header.Get(protocolcontract.MinimumServerRevisionHeader))
	if clientRevision == "" && minimumServerRevision == "" {
		return protocolcontract.ClientMetadata{
			ProtocolRevision:              protocolcontract.LegacyClientRevision,
			MinimumServerProtocolRevision: protocolcontract.MinimumSupportedServerRevision,
		}, nil
	}
	if clientRevision == "" || minimumServerRevision == "" {
		return protocolcontract.ClientMetadata{}, fmt.Errorf(
			"%s 与 %s 必须同时提供",
			protocolcontract.ClientRevisionHeader,
			protocolcontract.MinimumServerRevisionHeader,
		)
	}

	parsedClientRevision, err := positiveProtocolRevision(clientRevision)
	if err != nil {
		return protocolcontract.ClientMetadata{}, fmt.Errorf("%s 无效：%w", protocolcontract.ClientRevisionHeader, err)
	}
	parsedMinimumServerRevision, err := positiveProtocolRevision(minimumServerRevision)
	if err != nil {
		return protocolcontract.ClientMetadata{}, fmt.Errorf("%s 无效：%w", protocolcontract.MinimumServerRevisionHeader, err)
	}
	if parsedMinimumServerRevision > parsedClientRevision {
		return protocolcontract.ClientMetadata{}, fmt.Errorf(
			"%s 不能高于 %s",
			protocolcontract.MinimumServerRevisionHeader,
			protocolcontract.ClientRevisionHeader,
		)
	}
	return protocolcontract.ClientMetadata{
		ProtocolRevision:              parsedClientRevision,
		MinimumServerProtocolRevision: parsedMinimumServerRevision,
	}, nil
}

func positiveProtocolRevision(raw string) (int, error) {
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("期望正整数，实际为 %q", raw)
	}
	return value, nil
}
