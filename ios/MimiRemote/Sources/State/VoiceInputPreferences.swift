import Foundation

/// 语音提供方是设备级偏好。正式商店版本只开放设备端实时转写；
/// 旧值继续保留解码能力，便于升级时无损迁移，但不会再作为可选入口。
enum VoiceInputProvider: String, CaseIterable, Identifiable {
    static let storageKey = "voice.input.provider"
    static let appleTipAcknowledgedStorageKey = "voice.input.appleTipAcknowledged"

    case codex
    case apple

    var id: String { rawValue }

    static let storeAvailableCases: [VoiceInputProvider] = [.apple]

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input")
        case .apple:
            return L10n.text("ui.apple_voice_input")
        }
    }

    /// 每个选项直接说明主要取舍，避免用户还要把底部整段说明映射回具体提供方。
    var subtitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input_description")
        case .apple:
            return L10n.text("ui.apple_voice_input_description")
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "waveform"
        case .apple:
            return "waveform.badge.mic"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> VoiceInputProvider {
        // 中国大陆版本不把录音发送到第三方模型转写端点；旧 Codex 偏好和未知值统一迁移到设备端。
        guard defaults.string(forKey: storageKey) == VoiceInputProvider.apple.rawValue else {
            return .apple
        }
        return .apple
    }
}
