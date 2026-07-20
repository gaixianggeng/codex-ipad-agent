import Foundation

/// 面向用户和 App Review 的公开链接统一放在这里，避免设置页、测试和商店材料各自漂移。
/// 链接只指向公开仓库中的稳定文档，不携带设备、连接地址或任何用户标识。
enum AppExternalLinks {
    static let marketing = makeURL("https://github.com/gaixianggeng/mimi-remote")
    static let privacyPolicy = makeURL("https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md")
    static let termsOfUse = makeURL("https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md")
    static let support = makeURL("https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md")

    private static func makeURL(_ value: String) -> URL {
        guard let url = URL(string: value), url.scheme == "https" else {
            preconditionFailure("Invalid public HTTPS URL: \(value)")
        }
        return url
    }
}
