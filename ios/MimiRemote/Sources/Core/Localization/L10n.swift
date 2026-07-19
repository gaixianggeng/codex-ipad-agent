import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    static let preferenceKey = "app.language"

    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .simplifiedChinese, .english:
            return Locale(identifier: rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return L10n.text("ui.follow_system")
        case .simplifiedChinese:
            return L10n.text("ui.simplified_chinese")
        case .english:
            return L10n.text("ui.english")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: preferenceKey) else {
            return .system
        }
        return AppLanguage(rawValue: rawValue) ?? .system
    }
}

/// App UI strings must use a stable catalog key instead of embedding display copy in Swift.
///
/// `Bundle.localizedString` keeps dynamic keys compatible with the generated
/// `Localizable.xcstrings` bundle while allowing state-layer messages to share the same catalog.
enum L10n {
    static func text(_ key: String) -> String {
        text(key, language: AppLanguage.stored())
    }

    /// 指定语言资源包后，设置页切换语言可以即时刷新，无需修改系统语言或重启 App。
    static func text(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: Any...) -> String {
        formatTemplate(text(key), arguments: arguments)
    }

    /// Formatter implementation kept separate from Bundle lookup for deterministic tests.
    /// Catalog entries used by `format` are intentionally restricted to object placeholders
    /// (`%@`). Converting every argument to NSString keeps `Any` safe, including Int values.
    static func formatTemplate(_ template: String, arguments: [Any]) -> String {
        let cVarArgs: [CVarArg] = arguments.map {
            ($0 as? NSString) ?? (String(describing: $0) as NSString)
        }
        return String(format: template, locale: .autoupdatingCurrent, arguments: cVarArgs)
    }

    /// Use catalog plural variations for new count-dependent UI text.
    static func plural(_ key: String, count: Int) -> String {
        String.localizedStringWithFormat(text(key), count)
    }

    private static let localizedBundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: [AppLanguage.simplifiedChinese, .english].compactMap { language in
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path)
            else {
                return nil
            }
            return (language.rawValue, bundle)
        })
    }()

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard language != .system else {
            return .main
        }
        return localizedBundles[language.rawValue] ?? .main
    }
}
