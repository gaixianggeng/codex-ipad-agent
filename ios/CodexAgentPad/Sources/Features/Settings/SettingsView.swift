import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore

    let isInitialSetup: Bool

    @StateObject private var themeStore = ThemeStore()
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

                Section {
                    NavigationLink {
                        AppearanceView(themeStore: themeStore)
                    } label: {
                        Label("外观", systemImage: "paintpalette")
                    }

                    NavigationLink {
                        DoctorView()
                    } label: {
                        Label("诊断", systemImage: "stethoscope")
                    }
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
            .tint(themeStore.tokens(for: colorScheme).accent)
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

struct AppearanceView: View {
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: systemColorScheme)

        Form {
            Section {
                ForEach(ThemeMode.allCases) { mode in
                    Button {
                        themeStore.mode = mode
                    } label: {
                        ThemeModeRow(
                            mode: mode,
                            isSelected: themeStore.mode == mode,
                            tokens: tokens
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("主题")
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 10)], spacing: 10) {
                    ForEach(ThemeAccent.allCases) { accent in
                        AccentSwatchButton(
                            accent: accent,
                            isSelected: themeStore.accent == accent
                        ) {
                            themeStore.accent = accent
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("强调色")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Text(fontScaleText)
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { themeStore.fontScale },
                            set: { themeStore.setFontScale($0) }
                        ),
                        in: ThemeStore.minimumFontScale...ThemeStore.maximumFontScale,
                        step: 0.05
                    )
                    HStack(alignment: .firstTextBaseline) {
                        Text("Aa")
                            .font(.system(size: themeStore.scaledFontSize(13), weight: .medium))
                        Spacer()
                        Text("Aa")
                            .font(.system(size: themeStore.scaledFontSize(22), weight: .semibold))
                    }
                    .foregroundStyle(tokens.secondaryText)
                }
            }

            Section {
                AppearanceConversationPreview(themeStore: themeStore)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("聊天预览")
            }
        }
        .navigationTitle("外观")
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
    }

    private var fontScaleText: String {
        "\(Int((themeStore.fontScale * 100).rounded()))%"
    }
}

private struct ThemeModeRow: View {
    let mode: ThemeMode
    let isSelected: Bool
    let tokens: ThemeTokens

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? tokens.accent.opacity(0.18) : tokens.elevatedSurface)
                Image(systemName: iconName)
                    .foregroundStyle(isSelected ? tokens.accent : tokens.secondaryText)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(tokens.primaryText)
                Text(mode.subtitle)
                    .font(.footnote)
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tokens.accent)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch mode {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        case .highContrast:
            return "circle.circle"
        }
    }
}

private struct AccentSwatchButton: View {
    let accent: ThemeAccent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(accent.color)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
                .overlay {
                    Circle()
                        .stroke(isSelected ? accent.color : Color.secondary.opacity(0.22), lineWidth: isSelected ? 2 : 1)
                }

                Text(accent.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accent.title)强调色")
    }
}

private struct AppearanceConversationPreview: View {
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: systemColorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(themeStore.mode.title, systemImage: "sparkles")
                    .font(.system(size: themeStore.scaledFontSize(13), weight: .semibold))
                    .foregroundStyle(tokens.accent)
                Spacer()
                Text("Codex")
                    .font(.system(size: themeStore.scaledFontSize(12), weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }

            PreviewBubble(
                text: "帮我检查这个 PR 的风险点。",
                alignment: .trailing,
                fill: tokens.userBubble,
                textColor: tokens.primaryText,
                fontSize: themeStore.scaledFontSize(15)
            )

            PreviewBubble(
                text: "已开始检查。发现 2 个需要确认的改动，完整日志在 Inspector。",
                alignment: .leading,
                fill: tokens.assistantBubble,
                textColor: tokens.primaryText,
                fontSize: themeStore.scaledFontSize(15)
            )

            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("命令摘要")
                Spacer()
                Text("go test ./...")
                    .lineLimit(1)
            }
            .font(.system(size: themeStore.scaledFontSize(13), weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .padding(10)
            .background(tokens.systemBubble)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tokens.border, lineWidth: 1)
            }
        }
        .padding(12)
        .background(tokens.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

private struct PreviewBubble: View {
    enum AlignmentSide {
        case leading
        case trailing
    }

    let text: String
    let alignment: AlignmentSide
    let fill: Color
    let textColor: Color
    let fontSize: CGFloat

    var body: some View {
        HStack {
            if alignment == .trailing {
                Spacer(minLength: 36)
            }

            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if alignment == .leading {
                Spacer(minLength: 36)
            }
        }
    }
}
