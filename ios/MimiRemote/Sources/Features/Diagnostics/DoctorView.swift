import Foundation
import SwiftUI

struct DoctorView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var output = ""
    @State private var isRunning = false

    let showsHistoryDiagnostics: Bool

    init(showsHistoryDiagnostics: Bool = false) {
        self.showsHistoryDiagnostics = showsHistoryDiagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("检查 Mac 助手、Codex CLI、app-server gateway 和项目配置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !showsHistoryDiagnostics {
                    Text("历史诊断仅在设置里开启开发者模式后显示。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    Task { await runDoctor() }
                } label: {
                    if isRunning {
                        ProgressView()
                    } else {
                        Label("运行 Doctor", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)

                if showsHistoryDiagnostics {
                    Button {
                        Task { await runHistoryDiagnostics() }
                    } label: {
                        Label("历史诊断", systemImage: "clock.badge.questionmark")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }
            }

            ScrollView([.horizontal, .vertical]) {
                Text(output.isEmpty ? "尚未运行诊断" : output)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .navigationTitle("诊断")
    }

    private func runDoctor() async {
        isRunning = true
        defer { isRunning = false }
        do {
            let client = try appStore.client()
            let url = URL(string: AgentAPIClient.normalizedEndpoint(appStore.endpoint))!.appending(path: "/api/doctor")
            var request = URLRequest(url: url)
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            output = Self.formatDiagnosticPayload(data, fallback: "诊断结果不是 UTF-8")
            _ = client
        } catch {
            output = error.localizedDescription
        }
    }

    private func runHistoryDiagnostics() async {
        isRunning = true
        defer { isRunning = false }
        do {
            guard var components = URLComponents(string: AgentAPIClient.normalizedEndpoint(appStore.endpoint)) else {
                output = "Endpoint 无效"
                return
            }
            components.path = "/api/debug/codex-history"
            var queryItems = [URLQueryItem(name: "limit", value: "120")]
            if let projectID = sessionStore.selectedProjectID {
                queryItems.append(URLQueryItem(name: "project_id", value: projectID))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                output = "诊断 URL 无效"
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            output = Self.formatDiagnosticPayload(data, fallback: "历史诊断结果不是 UTF-8")
        } catch {
            output = error.localizedDescription
        }
    }

    private static func formatDiagnosticPayload(_ data: Data, fallback: String) -> String {
        // 诊断接口默认返回紧凑 JSON；本地格式化能让 iPad 上的 rows/counts 更容易排查。
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
}
