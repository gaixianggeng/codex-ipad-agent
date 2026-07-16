import Foundation
import SwiftUI
import UIKit

struct DoctorDiagnosticReport: Decodable, Equatable {
    let ok: Bool
    let version: String
    let listen: String
    let checks: [DoctorDiagnosticCheck]
}

struct DoctorDiagnosticCheck: Decodable, Equatable, Identifiable {
    let name: String
    let ok: Bool
    let level: String?
    let message: String
    let fix: String?

    var id: String { name }

    var displayName: String {
        switch name {
        case "token": return "访问令牌"
        case "projects": return "项目配置"
        case "codex": return "Codex CLI"
        case "runtime": return "Agent Runtime"
        case "tailscale": return "Tailscale"
        case "config-file": return "配置文件权限"
        case "app-server-token-file": return "app-server 凭据文件"
        case "codex-app-server": return "Codex app-server"
        case "claude-bridge": return "Claude bridge"
        case "app-server": return "app-server gateway"
        case "agentd-port": return "agentd 端口"
        case "app-server-port": return "app-server 端口"
        default: return name
        }
    }

    var normalizedFix: String? {
        let value = fix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var isWarning: Bool {
        !ok && level == "warning"
    }
}

struct DoctorDiagnosticDocument: Equatable {
    let report: DoctorDiagnosticReport
    let rawJSON: String
}

enum DoctorDiagnosticError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidHTTPResponse
    case httpStatus(code: Int, message: String?)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Mac 助手地址无效，请返回设置检查连接地址。"
        case .invalidHTTPResponse:
            return "Mac 助手返回了无法识别的网络响应。"
        case .httpStatus(let code, let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.isEmpty {
                return "诊断请求失败（HTTP \(code)），请检查 Mac 助手状态后重试。"
            }
            return "诊断请求失败（HTTP \(code)）：\(detail)"
        case .invalidPayload(let detail):
            return "诊断结果格式无法识别：\(detail)"
        }
    }
}

enum DoctorDiagnosticsParser {
    static func doctorURL(endpoint: String) throws -> URL {
        guard var components = URLComponents(string: AgentAPIClient.normalizedEndpoint(endpoint)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw DoctorDiagnosticError.invalidEndpoint
        }
        components.path = "/api/doctor"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw DoctorDiagnosticError.invalidEndpoint
        }
        return url
    }

    static func parseDoctorResponse(data: Data, response: URLResponse) throws -> DoctorDiagnosticDocument {
        try validate(data: data, response: response)
        do {
            let report = try JSONDecoder().decode(DoctorDiagnosticReport.self, from: data)
            return DoctorDiagnosticDocument(
                report: report,
                rawJSON: formatDiagnosticPayload(data, fallback: "诊断结果不是 UTF-8")
            )
        } catch {
            throw DoctorDiagnosticError.invalidPayload(error.localizedDescription)
        }
    }

    static func parseRawResponse(data: Data, response: URLResponse, fallback: String) throws -> String {
        try validate(data: data, response: response)
        return formatDiagnosticPayload(data, fallback: fallback)
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DoctorDiagnosticError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DoctorDiagnosticError.httpStatus(
                code: http.statusCode,
                message: serverErrorMessage(from: data)
            )
        }
    }

    static func formatDiagnosticPayload(_ data: Data, fallback: String) -> String {
        // 诊断接口默认返回紧凑 JSON；本地排序和缩进便于复制给排障人员。
        if let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
           ),
           let prettyText = String(data: prettyData, encoding: .utf8) {
            return prettyText
        }
        return String(data: data, encoding: .utf8) ?? fallback
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error"] {
                if let value = object[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                if let nested = object[key] as? [String: Any],
                   let value = nested["message"] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}

private enum DoctorOperation {
    case doctor
    case history
}

private enum DoctorLoadState: Equatable {
    case idle
    case loading
    case loaded(DoctorDiagnosticDocument)
    case failed(String)
}

private enum HistoryDiagnosticLoadState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}

struct DoctorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var doctorState: DoctorLoadState = .idle
    @State private var historyState: HistoryDiagnosticLoadState = .idle
    @State private var activeOperation: DoctorOperation?
    @State private var isRawJSONExpanded = false
    @State private var isHistoryJSONExpanded = false

    let showsHistoryDiagnostics: Bool

    init(showsHistoryDiagnostics: Bool = false) {
        self.showsHistoryDiagnostics = showsHistoryDiagnostics
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introduction(tokens: tokens)
                actionBar(tokens: tokens)
                doctorContent(tokens: tokens)
                if showsHistoryDiagnostics {
                    historyContent(tokens: tokens)
                }
            }
            .padding()
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("诊断")
        .tint(tokens.accent)
        .task {
            guard doctorState == .idle else {
                return
            }
            await runDoctor()
        }
    }

    private func introduction(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("检查 Mac 助手、Codex CLI、app-server gateway 和项目配置。")
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
            if !showsHistoryDiagnostics {
                Text("历史诊断仅在设置里开启开发者模式后显示。")
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
    }

    private func actionBar(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await runDoctor() }
            } label: {
                if activeOperation == .doctor {
                    Label("检查中", systemImage: "hourglass")
                } else {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.primaryAction)
            .foregroundStyle(tokens.primaryActionForeground)
            .disabled(activeOperation != nil)
            .accessibilityHint("重新请求 Mac 助手的 Doctor 诊断结果")

            if showsHistoryDiagnostics {
                Button {
                    Task { await runHistoryDiagnostics() }
                } label: {
                    if activeOperation == .history {
                        Label("加载历史诊断", systemImage: "hourglass")
                    } else {
                        Label("历史诊断", systemImage: "clock.badge.questionmark")
                    }
                }
                .buttonStyle(.bordered)
                .tint(tokens.accent)
                .disabled(activeOperation != nil)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func doctorContent(tokens: ThemeTokens) -> some View {
        switch doctorState {
        case .idle:
            diagnosticPlaceholder(
                title: "尚未运行诊断",
                message: "点击重新检查从 Mac 助手获取状态。",
                systemImage: "stethoscope",
                tokens: tokens
            )
        case .loading:
            loadingCard(tokens: tokens)
        case .failed(let message):
            errorCard(message: message, tokens: tokens)
        case .loaded(let document):
            diagnosticReport(document, tokens: tokens)
        }
    }

    private func loadingCard(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text("正在运行 Doctor")
                    .font(themeStore.uiFont(.headline))
                    .foregroundStyle(tokens.primaryText)
                Text("正在等待 Mac 助手返回检查结果……")
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorCard(message: String, tokens: ThemeTokens) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            Label("诊断请求失败", systemImage: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(.headline))
                .foregroundStyle(.red)
            Text(message)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.primaryText)
                .textSelection(.enabled)
            Button {
                Task { await runDoctor() }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(activeOperation != nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.22), lineWidth: 1)
        }
    }

    private func diagnosticReport(_ document: DoctorDiagnosticDocument, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryCard(document.report, tokens: tokens)

            VStack(alignment: .leading, spacing: 10) {
                Text("检查项")
                    .font(themeStore.uiFont(.headline))
                    .foregroundStyle(tokens.primaryText)
                ForEach(document.report.checks) { check in
                    checkRow(check, tokens: tokens)
                }
            }

            rawJSONSection(
                title: "Doctor 原始 JSON",
                text: document.rawJSON,
                isExpanded: $isRawJSONExpanded,
                tokens: tokens
            )
        }
    }

    private func summaryCard(_ report: DoctorDiagnosticReport, tokens: ThemeTokens) -> some View {
        let warningCount = report.checks.filter(\.isWarning).count
        let hasWarnings = report.ok && warningCount > 0
        let iconName = report.ok
            ? (hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            : "xmark.octagon.fill"
        let statusColor: Color = report.ok
            ? (hasWarnings ? tokens.warning : .green)
            : .red

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.ok ? (hasWarnings ? "服务可用，有提醒" : "服务可用") : "发现需要处理的问题")
                        .font(themeStore.uiFont(.headline))
                        .foregroundStyle(tokens.primaryText)
                    Text(report.ok
                        ? (hasWarnings ? "必要检查已通过，另有 \(warningCount) 项可选建议。" : "Doctor 的所有必要检查已通过。")
                        : "查看下方失败项的处理建议，完成后重新检查。")
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }
                Spacer(minLength: 0)
            }

            Divider()
            LabeledContent("服务版本", value: report.version.isEmpty ? "未知" : report.version)
            LabeledContent("监听地址", value: report.listen.isEmpty ? "未配置" : report.listen)
        }
        .font(themeStore.uiFont(.callout))
        .padding(16)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func checkRow(_ check: DoctorDiagnosticCheck, tokens: ThemeTokens) -> some View {
        let iconName = check.ok
            ? "checkmark.circle.fill"
            : (check.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
        let statusColor: Color = check.ok ? .green : (check.isWarning ? tokens.warning : .red)
        let statusLabel = check.ok ? "已通过" : (check.isWarning ? "提醒" : "未通过")

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusColor)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(check.displayName)
                        .font(themeStore.uiFont(.subheadline).weight(.semibold))
                        .foregroundStyle(tokens.primaryText)
                    if check.displayName != check.name {
                        Text(check.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
                Text(check.message)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !check.ok, let fix = check.normalizedFix {
                    Label(fix, systemImage: "wrench.and.screwdriver")
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.primaryText)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tokens.codeBlock, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(check.ok ? tokens.border : statusColor.opacity(0.28), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func historyContent(tokens: ThemeTokens) -> some View {
        switch historyState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在加载历史诊断……")
                    .foregroundStyle(tokens.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("历史诊断加载失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .textSelection(.enabled)
            }
        case .loaded(let text):
            rawJSONSection(
                title: "历史诊断 JSON",
                text: text,
                isExpanded: $isHistoryJSONExpanded,
                tokens: tokens
            )
        }
    }

    private func rawJSONSection(
        title: String,
        text: String,
        isExpanded: Binding<Bool>,
        tokens: ThemeTokens
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("复制原始 JSON", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("将完整诊断内容复制到剪贴板")
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(12)
                .background(tokens.codeBlock, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.top, 8)
        } label: {
            Label(title, systemImage: "chevron.left.forwardslash.chevron.right")
                .font(themeStore.uiFont(.subheadline).weight(.semibold))
                .foregroundStyle(tokens.primaryText)
        }
        .padding(14)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func diagnosticPlaceholder(
        title: String,
        message: String,
        systemImage: String,
        tokens: ThemeTokens
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .foregroundStyle(tokens.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @MainActor
    private func runDoctor() async {
        guard activeOperation == nil else {
            return
        }
        activeOperation = .doctor
        doctorState = .loading
        defer { activeOperation = nil }

        do {
            let url = try DoctorDiagnosticsParser.doctorURL(endpoint: appStore.connectionEndpoint)
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            doctorState = .loaded(try DoctorDiagnosticsParser.parseDoctorResponse(data: data, response: response))
        } catch is CancellationError {
            doctorState = .idle
        } catch {
            doctorState = .failed(displayMessage(for: error))
        }
    }

    @MainActor
    private func runHistoryDiagnostics() async {
        guard activeOperation == nil else {
            return
        }
        activeOperation = .history
        historyState = .loading
        defer { activeOperation = nil }

        do {
            guard var components = URLComponents(string: AgentAPIClient.normalizedEndpoint(appStore.connectionEndpoint)) else {
                throw DoctorDiagnosticError.invalidEndpoint
            }
            components.path = "/api/debug/codex-history"
            var queryItems = [URLQueryItem(name: "limit", value: "120")]
            if let projectID = sessionStore.selectedProjectID {
                queryItems.append(URLQueryItem(name: "project_id", value: projectID))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw DoctorDiagnosticError.invalidEndpoint
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            historyState = .loaded(try DoctorDiagnosticsParser.parseRawResponse(
                data: data,
                response: response,
                fallback: "历史诊断结果不是 UTF-8"
            ))
            isHistoryJSONExpanded = true
        } catch is CancellationError {
            historyState = .idle
        } catch {
            historyState = .failed(displayMessage(for: error))
        }
    }

    private func displayMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return "当前设备没有网络连接。恢复网络后再重新检查。"
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return "无法连接到 Mac 助手。请确认助手正在运行，并检查连接地址和网络。"
        case .timedOut:
            return "连接 Mac 助手超时。请确认助手正在运行，然后重试。"
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return "访问码验证失败，请在 Mac 连接设置中重新配对。"
        default:
            // 未知 URL 错误保留稳定的中文说明和错误码，便于支持人员定位且不泄露底层英文文案。
            return "网络请求失败（错误码 \(urlError.errorCode)），请稍后重试。"
        }
    }
}
