#if DEBUG
import Foundation

/// 统一解析仅用于本地开发与视觉验收的启动参数。
///
/// 将调试配置与 AppStore 的生产状态职责分离，避免预览能力继续扩大核心状态文件。
struct DebugLaunchConfiguration {
    let opensWorkbenchWithoutPairing: Bool
    let seedsWorkbenchUI: Bool
    let seedsQueuedTurnsUI: Bool
    let seedsMCPApprovalUI: Bool
    let hostPlatformPreview: HostPlatform?
    let endpoint: String?
    let token: String?

    static func current(processInfo: ProcessInfo = .processInfo) -> DebugLaunchConfiguration {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        let seedsQueuedTurnsUI = arguments.contains("--debug-seed-queue-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_QUEUE_UI"])
        let seedsMCPApprovalUI = arguments.contains("--debug-seed-mcp-approval-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_MCP_APPROVAL_UI"])
        let hostPlatformPreview = argumentValue(named: "--debug-host-platform", in: arguments)
            .map { HostPlatform(serverValue: $0) }
        return DebugLaunchConfiguration(
            opensWorkbenchWithoutPairing: arguments.contains("--debug-skip-pairing")
                || boolValue(environment["MIMI_DEBUG_SKIP_PAIRING"])
                || hostPlatformPreview != nil,
            seedsWorkbenchUI: arguments.contains("--debug-seed-ui")
                || boolValue(environment["MIMI_DEBUG_SEED_UI"])
                || seedsQueuedTurnsUI
                || seedsMCPApprovalUI,
            seedsQueuedTurnsUI: seedsQueuedTurnsUI,
            seedsMCPApprovalUI: seedsMCPApprovalUI,
            hostPlatformPreview: hostPlatformPreview,
            endpoint: argumentValue(named: "--debug-endpoint", in: arguments)
                ?? environment["MIMI_DEBUG_ENDPOINT"],
            token: argumentValue(named: "--debug-token", in: arguments)
                ?? environment["MIMI_DEBUG_TOKEN"]
        )
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = "\(name)="
        if let inlineValue = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            let value = String(inlineValue.dropFirst(inlinePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex),
              !arguments[valueIndex].hasPrefix("--") else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func boolValue(_ rawValue: String?) -> Bool {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}
#endif
