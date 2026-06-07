package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type workspaceResolveRequest struct {
	Path string `json:"path"`
}

type workspaceResolveResponse struct {
	Workspace workspaceDescriptor `json:"workspace"`
}

type workspaceDescriptor struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Path            string `json:"path"`
	RootProjectID   string `json:"root_project_id"`
	RootProjectName string `json:"root_project_name"`
	RootProjectPath string `json:"root_project_path"`
	Trusted         bool   `json:"trusted"`
	CanStartSession bool   `json:"can_start_session"`
}

func (r *Router) workspaceResolveHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload workspaceResolveRequest
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体不是合法 JSON")
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	project, realPath, ok := r.projectForGatewayPathWithRealPath(path)
	if !ok {
		// 不区分“不存在”和“不在 allowlist 内”，避免把 resolve 变成远程文件系统探测接口。
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return
	}

	writeJSON(w, http.StatusOK, workspaceResolveResponse{
		Workspace: workspaceDescriptor{
			ID:              workspaceIDForRealPath(realPath),
			Name:            filepath.Base(realPath),
			Path:            realPath,
			RootProjectID:   project.ID,
			RootProjectName: project.Name,
			RootProjectPath: project.Path,
			Trusted:         true,
			CanStartSession: true,
		},
	})
}

func workspaceIDForRealPath(realPath string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(realPath)))
	return "ws_" + hex.EncodeToString(sum[:])[:16]
}
