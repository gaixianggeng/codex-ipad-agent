import Foundation

struct MediaPreviewPayload: Sendable {
    let name: String
    let contentBase64: String

    init(response: FileReadResponse) {
        name = response.name
        contentBase64 = response.contentBase64
    }
}

/// 串行处理文件预览的 Base64 解码与临时文件写入。
///
/// SessionStore 运行在 MainActor；把同步文件工作收口到独立 actor 后，大文件预览不会占用 UI
/// 执行器。串行执行也能限制同时解码多份大 Base64 时的瞬时内存峰值。
actor MediaWorker {
    static let shared = MediaWorker()

    private let previewRootDirectory: URL

#if DEBUG
    private var lastPreviewWorkWasOnMainThread = false
#endif

    init(
        previewRootDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiRemotePreviews", isDirectory: true)
    ) {
        self.previewRootDirectory = previewRootDirectory
    }

    func previewURL(
        from payload: MediaPreviewPayload,
        profileID: String
    ) throws -> URL {
        try Task.checkCancellation()

#if DEBUG
        lastPreviewWorkWasOnMainThread = Thread.isMainThread
#endif

        guard let data = Data(base64Encoded: payload.contentBase64) else {
            throw FilePreviewStoreError.invalidPayload
        }
        try Task.checkCancellation()

        // 每个 Profile 使用独立临时目录，后续删除设备档案时可以定向清理；
        // 目录名只保存不可逆摘要，不把 endpoint 或其他连接信息写入文件系统。
        let directory = previewRootDirectory.appendingPathComponent(
            Self.profileDirectoryComponent(profileID),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Task.checkCancellation()

        let filename = Self.safePreviewFilename(payload.name)
        let url = directory.appendingPathComponent(
            "\(UUID().uuidString)-\(filename)",
            isDirectory: false
        )

        do {
            try data.write(to: url, options: [.atomic])
            try Task.checkCancellation()
            return url
        } catch is CancellationError {
            // 取消发生在原子写入完成之后时也移除无消费者的文件，避免反复切换主机留下垃圾。
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
    }

    func discardPreview(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

#if DEBUG
    func lastPreviewWorkRanOnMainThreadForTesting() -> Bool {
        lastPreviewWorkWasOnMainThread
    }
#endif

    nonisolated static func safePreviewFilename(_ rawName: String) -> String {
        let fallback = "preview"
        let lastComponent = (rawName as NSString)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastComponent.isEmpty else {
            return fallback
        }
        let blocked = CharacterSet(charactersIn: "/\\:\u{0}")
        let cleaned = lastComponent
            .components(separatedBy: blocked)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private nonisolated static func profileDirectoryComponent(_ profileID: String) -> String {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? "legacy" : normalized
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
