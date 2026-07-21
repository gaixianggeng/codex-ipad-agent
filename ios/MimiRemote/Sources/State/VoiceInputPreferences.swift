import Foundation

/// 语音提供方是设备级偏好；缺失或未来版本写入未知值时必须回到现有 Codex 链路。
enum VoiceInputProvider: String, CaseIterable, Identifiable {
    static let storageKey = "voice.input.provider"
    static let appleTipAcknowledgedStorageKey = "voice.input.appleTipAcknowledged"

    case codex
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input")
        case .apple:
            return L10n.text("ui.apple_voice_input")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> VoiceInputProvider {
        guard let rawValue = defaults.string(forKey: storageKey) else {
            return .codex
        }
        return VoiceInputProvider(rawValue: rawValue) ?? .codex
    }
}
