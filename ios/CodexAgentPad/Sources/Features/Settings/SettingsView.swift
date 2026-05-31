import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore

    let isInitialSetup: Bool

    @State private var endpoint = ""
    @State private var token = ""
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:8787", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("agentd Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("连接")
                } footer: {
                    Text("Token 存入 Keychain，Endpoint 存入 UserDefaults。MVP 只建议在本机或 Tailscale 网络中使用。")
                }

                Section {
                    Button {
                        Task { await appStore.testConnection(endpoint: endpoint, token: token) }
                    } label: {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                    }

                    Button {
                        save()
                    } label: {
                        Label("保存并加载", systemImage: "checkmark.circle")
                    }
                    .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    HStack {
                        Text("连接")
                        Spacer()
                        Text(appStore.connectionStatus.title)
                            .foregroundStyle(statusColor)
                    }
                    if let message = appStore.lastError ?? localError {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } header: {
                    Text("状态")
                }
            }
            .navigationTitle(isInitialSetup ? "连接 agentd" : "设置")
            .toolbar {
                if !isInitialSetup {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .onAppear {
                endpoint = appStore.endpoint
                token = appStore.token
            }
        }
    }

    private var statusColor: Color {
        switch appStore.connectionStatus {
        case .connected:
            return .green
        case .failed:
            return .red
        case .testing:
            return .orange
        case .idle:
            return .secondary
        }
    }

    private func save() {
        do {
            try appStore.save(endpoint: endpoint, token: token)
            localError = nil
            Task {
                await sessionStore.refreshAll(autoAttach: true)
                if !isInitialSetup {
                    dismiss()
                }
            }
        } catch {
            localError = error.localizedDescription
        }
    }
}
