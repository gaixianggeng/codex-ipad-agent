package protocolcontract

import (
	"fmt"
	"runtime"
)

// VersionResponse 是 agentd /api/version 的稳定线协议。
// 新字段只能以向后兼容方式增加；现有 JSON 名称和语义由共享 golden fixture 锁定。
type VersionResponse struct {
	Name                          string   `json:"name"`
	Version                       string   `json:"version"`
	InstallationID                string   `json:"installation_id"`
	Platform                      string   `json:"platform"`
	ProtocolRevision              int      `json:"protocol_revision"`
	MinimumClientProtocolRevision int      `json:"minimum_client_protocol_revision"`
	Capabilities                  []string `json:"capabilities"`
}

func CurrentVersionResponse(version string, installationID string) VersionResponse {
	return VersionResponse{
		Name:                          "agentd",
		Version:                       version,
		InstallationID:                installationID,
		Platform:                      runtime.GOOS,
		ProtocolRevision:              CurrentRevision,
		MinimumClientProtocolRevision: MinimumSupportedClientRevision,
		Capabilities:                  Capabilities(),
	}
}

type ClientMetadata struct {
	ProtocolRevision              int
	MinimumServerProtocolRevision int
}

type CompatibilityError struct {
	Code                          string
	Message                       string
	ClientProtocolRevision        int
	MinimumServerProtocolRevision int
	ServerProtocolRevision        int
	MinimumClientProtocolRevision int
}

func (e *CompatibilityError) Error() string {
	return e.Message
}

// CheckClient 只判断双方声明的最低要求，不因客户端修订号更高就拒绝。
// 这样纯加法的新客户端仍可连接旧服务；若它依赖新语义，必须提高 minimum server revision。
func CheckClient(metadata ClientMetadata) *CompatibilityError {
	if metadata.ProtocolRevision < MinimumSupportedClientRevision {
		return &CompatibilityError{
			Code:                          "protocol_incompatible",
			Message:                       fmt.Sprintf("客户端协议修订 %d 低于 agentd 最低兼容修订 %d；请升级 Mimi Remote", metadata.ProtocolRevision, MinimumSupportedClientRevision),
			ClientProtocolRevision:        metadata.ProtocolRevision,
			MinimumServerProtocolRevision: metadata.MinimumServerProtocolRevision,
			ServerProtocolRevision:        CurrentRevision,
			MinimumClientProtocolRevision: MinimumSupportedClientRevision,
		}
	}
	if metadata.MinimumServerProtocolRevision > CurrentRevision {
		return &CompatibilityError{
			Code:                          "protocol_incompatible",
			Message:                       fmt.Sprintf("客户端要求 agentd 协议至少为 %d，当前为 %d；请升级 agentd", metadata.MinimumServerProtocolRevision, CurrentRevision),
			ClientProtocolRevision:        metadata.ProtocolRevision,
			MinimumServerProtocolRevision: metadata.MinimumServerProtocolRevision,
			ServerProtocolRevision:        CurrentRevision,
			MinimumClientProtocolRevision: MinimumSupportedClientRevision,
		}
	}
	return nil
}
