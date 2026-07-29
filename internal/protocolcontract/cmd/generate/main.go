package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type manifest struct {
	SchemaVersion                  int      `json:"schema_version"`
	ProtocolName                   string   `json:"protocol_name"`
	CurrentRevision                int      `json:"current_revision"`
	MinimumSupportedClientRevision int      `json:"minimum_supported_client_revision"`
	MinimumSupportedServerRevision int      `json:"minimum_supported_server_revision"`
	LegacyClientRevision           int      `json:"legacy_client_revision"`
	LegacyServerRevision           int      `json:"legacy_server_revision"`
	Headers                        headers  `json:"headers"`
	Capabilities                   []string `json:"capabilities"`
}

type headers struct {
	ClientRevision        string `json:"client_revision"`
	MinimumServerRevision string `json:"minimum_server_revision"`
	ServerRevision        string `json:"server_revision"`
	MinimumClientRevision string `json:"minimum_client_revision"`
}

type generatedFile struct {
	path    string
	content []byte
}

func main() {
	write := flag.Bool("write", false, "将生成结果写回仓库")
	check := flag.Bool("check", false, "检查生成结果是否为最新")
	flag.Parse()

	if *write && *check {
		fatal(errors.New("--write 与 --check 不能同时使用"))
	}
	if !*write && !*check {
		*check = true
	}

	root, err := repositoryRoot()
	if err != nil {
		fatal(err)
	}
	manifestPath := filepath.Join(root, "contracts", "mimi-protocol", "contract.json")
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		fatal(fmt.Errorf("读取权威契约失败：%w", err))
	}

	var spec manifest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&spec); err != nil {
		fatal(fmt.Errorf("解析权威契约失败：%w", err))
	}
	if err := validate(spec); err != nil {
		fatal(err)
	}

	hash := sha256.Sum256(raw)
	sourceHash := hex.EncodeToString(hash[:])
	files, err := render(root, spec, sourceHash)
	if err != nil {
		fatal(err)
	}

	for _, file := range files {
		if *write {
			if err := os.MkdirAll(filepath.Dir(file.path), 0o755); err != nil {
				fatal(err)
			}
			if err := os.WriteFile(file.path, file.content, 0o644); err != nil {
				fatal(err)
			}
			fmt.Printf("已更新 %s\n", relative(root, file.path))
			continue
		}

		current, err := os.ReadFile(file.path)
		if err != nil {
			fatal(fmt.Errorf("%s 不存在或不可读，请先使用 --write：%w", relative(root, file.path), err))
		}
		if !bytes.Equal(current, file.content) {
			fatal(fmt.Errorf("%s 已过期，请运行 go run ./internal/protocolcontract/cmd/generate --write", relative(root, file.path)))
		}
	}

	if *check {
		fmt.Println("Mimi 协议生成文件与权威契约一致。")
	}
}

func repositoryRoot() (string, error) {
	current, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(current, "go.mod")); err == nil {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", errors.New("找不到包含 go.mod 的仓库根目录")
		}
		current = parent
	}
}

func validate(spec manifest) error {
	if spec.SchemaVersion != 1 {
		return fmt.Errorf("不支持的 contract schema_version：%d", spec.SchemaVersion)
	}
	if strings.TrimSpace(spec.ProtocolName) == "" {
		return errors.New("protocol_name 不能为空")
	}
	if spec.CurrentRevision <= 0 ||
		spec.MinimumSupportedClientRevision <= 0 ||
		spec.MinimumSupportedServerRevision <= 0 ||
		spec.LegacyClientRevision <= 0 ||
		spec.LegacyServerRevision <= 0 {
		return errors.New("所有协议修订号都必须为正整数")
	}
	if spec.MinimumSupportedClientRevision > spec.CurrentRevision {
		return errors.New("minimum_supported_client_revision 不能高于 current_revision")
	}
	if spec.MinimumSupportedServerRevision > spec.CurrentRevision {
		return errors.New("minimum_supported_server_revision 不能高于 current_revision")
	}
	if spec.LegacyClientRevision > spec.CurrentRevision {
		return errors.New("legacy_client_revision 不能高于 current_revision")
	}
	if spec.LegacyServerRevision > spec.CurrentRevision {
		return errors.New("legacy_server_revision 不能高于 current_revision")
	}
	headerValues := []string{
		spec.Headers.ClientRevision,
		spec.Headers.MinimumServerRevision,
		spec.Headers.ServerRevision,
		spec.Headers.MinimumClientRevision,
	}
	seenHeaders := map[string]bool{}
	for _, header := range headerValues {
		if strings.TrimSpace(header) == "" || seenHeaders[header] {
			return errors.New("协议 header 必须非空且互不相同")
		}
		seenHeaders[header] = true
	}

	seen := map[string]bool{}
	for _, capability := range spec.Capabilities {
		if strings.TrimSpace(capability) == "" {
			return errors.New("capabilities 不能包含空值")
		}
		if seen[capability] {
			return fmt.Errorf("capabilities 包含重复值：%s", capability)
		}
		seen[capability] = true
	}
	return nil
}

func render(root string, spec manifest, sourceHash string) ([]generatedFile, error) {
	capabilities := append([]string(nil), spec.Capabilities...)
	sort.Strings(capabilities)

	goSource, err := renderGo(spec, capabilities, sourceHash)
	if err != nil {
		return nil, err
	}
	swiftSource := renderSwift(spec, capabilities, sourceHash)
	return []generatedFile{
		{
			path:    filepath.Join(root, "internal", "protocolcontract", "generated.go"),
			content: goSource,
		},
		{
			path:    filepath.Join(root, "ios", "MimiRemote", "Sources", "Core", "Models", "ProtocolContract.generated.swift"),
			content: swiftSource,
		},
	}, nil
}

func renderGo(spec manifest, capabilities []string, sourceHash string) ([]byte, error) {
	var source strings.Builder
	source.WriteString("// Code generated by internal/protocolcontract/cmd/generate; DO NOT EDIT.\n")
	source.WriteString("// Source: contracts/mimi-protocol/contract.json\n\n")
	source.WriteString("package protocolcontract\n\n")
	source.WriteString("const (\n")
	fmt.Fprintf(&source, "\tSchemaVersion = %d\n", spec.SchemaVersion)
	fmt.Fprintf(&source, "\tProtocolName = %q\n", spec.ProtocolName)
	fmt.Fprintf(&source, "\tCurrentRevision = %d\n", spec.CurrentRevision)
	fmt.Fprintf(&source, "\tMinimumSupportedClientRevision = %d\n", spec.MinimumSupportedClientRevision)
	fmt.Fprintf(&source, "\tMinimumSupportedServerRevision = %d\n", spec.MinimumSupportedServerRevision)
	fmt.Fprintf(&source, "\tLegacyClientRevision = %d\n", spec.LegacyClientRevision)
	fmt.Fprintf(&source, "\tLegacyServerRevision = %d\n", spec.LegacyServerRevision)
	fmt.Fprintf(&source, "\tClientRevisionHeader = %q\n", spec.Headers.ClientRevision)
	fmt.Fprintf(&source, "\tMinimumServerRevisionHeader = %q\n", spec.Headers.MinimumServerRevision)
	fmt.Fprintf(&source, "\tServerRevisionHeader = %q\n", spec.Headers.ServerRevision)
	fmt.Fprintf(&source, "\tMinimumClientRevisionHeader = %q\n", spec.Headers.MinimumClientRevision)
	fmt.Fprintf(&source, "\tSpecSHA256 = %q\n", sourceHash)
	source.WriteString(")\n\n")
	source.WriteString("var currentCapabilities = []string{\n")
	for _, capability := range capabilities {
		fmt.Fprintf(&source, "\t%q,\n", capability)
	}
	source.WriteString("}\n\n")
	source.WriteString("// Capabilities 返回副本，避免调用方修改进程级权威能力集合。\n")
	source.WriteString("func Capabilities() []string {\n")
	source.WriteString("\treturn append([]string(nil), currentCapabilities...)\n")
	source.WriteString("}\n")

	formatted, err := format.Source([]byte(source.String()))
	if err != nil {
		return nil, fmt.Errorf("格式化 Go 生成文件失败：%w", err)
	}
	return formatted, nil
}

func renderSwift(spec manifest, capabilities []string, sourceHash string) []byte {
	var source strings.Builder
	source.WriteString("// Code generated by internal/protocolcontract/cmd/generate; DO NOT EDIT.\n")
	source.WriteString("// Source: contracts/mimi-protocol/contract.json\n\n")
	source.WriteString("import Foundation\n\n")
	source.WriteString("enum MimiProtocolContract {\n")
	fmt.Fprintf(&source, "    static let schemaVersion = %d\n", spec.SchemaVersion)
	fmt.Fprintf(&source, "    static let protocolName = %s\n", swiftString(spec.ProtocolName))
	fmt.Fprintf(&source, "    static let currentRevision = %d\n", spec.CurrentRevision)
	fmt.Fprintf(&source, "    static let minimumSupportedClientRevision = %d\n", spec.MinimumSupportedClientRevision)
	fmt.Fprintf(&source, "    static let minimumSupportedServerRevision = %d\n", spec.MinimumSupportedServerRevision)
	fmt.Fprintf(&source, "    static let legacyClientRevision = %d\n", spec.LegacyClientRevision)
	fmt.Fprintf(&source, "    static let legacyServerRevision = %d\n", spec.LegacyServerRevision)
	fmt.Fprintf(&source, "    static let clientRevisionHeader = %s\n", swiftString(spec.Headers.ClientRevision))
	fmt.Fprintf(&source, "    static let minimumServerRevisionHeader = %s\n", swiftString(spec.Headers.MinimumServerRevision))
	fmt.Fprintf(&source, "    static let serverRevisionHeader = %s\n", swiftString(spec.Headers.ServerRevision))
	fmt.Fprintf(&source, "    static let minimumClientRevisionHeader = %s\n", swiftString(spec.Headers.MinimumClientRevision))
	fmt.Fprintf(&source, "    static let specSHA256 = %s\n", swiftString(sourceHash))
	source.WriteString("    static let declaredCapabilities: Set<String> = [\n")
	for _, capability := range capabilities {
		fmt.Fprintf(&source, "        %s,\n", swiftString(capability))
	}
	source.WriteString("    ]\n\n")
	source.WriteString("    /// REST 与 WebSocket 共用同一组握手 header，旧 agentd 会安全忽略未知 header。\n")
	source.WriteString("    static func applyClientHeaders(to request: inout URLRequest) {\n")
	source.WriteString("        request.setValue(String(currentRevision), forHTTPHeaderField: clientRevisionHeader)\n")
	source.WriteString("        request.setValue(String(minimumSupportedServerRevision), forHTTPHeaderField: minimumServerRevisionHeader)\n")
	source.WriteString("    }\n")
	source.WriteString("}\n")
	return []byte(source.String())
}

func swiftString(value string) string {
	raw, _ := json.Marshal(value)
	return string(raw)
}

func relative(root string, path string) string {
	value, err := filepath.Rel(root, path)
	if err != nil {
		return path
	}
	return filepath.ToSlash(value)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "Mimi 协议生成失败："+err.Error())
	os.Exit(1)
}
