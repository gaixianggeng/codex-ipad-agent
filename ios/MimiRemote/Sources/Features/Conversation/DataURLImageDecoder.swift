import Foundation
import ImageIO
import UIKit

/// SwiftUI 图片任务与共享缓存共同使用的稳定身份。
///
/// resourceID 可能只是远端 session/media/path；必须同时带 Profile，避免两台 Mac 使用相同
/// ID 时复用旧视图任务或已解码图片。
struct MediaRequestIdentity: Hashable, Sendable {
    let profileID: String
    let resourceID: String

    init(profileID: String, resourceID: String) {
        let trimmedProfileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileID = trimmedProfileID.isEmpty ? "legacy" : trimmedProfileID
        self.resourceID = resourceID
    }
}

/// 统一处理对话与附件中的 data URL 图片，避免 SwiftUI `body` 重算时反复做 Base64 和图片解码。
enum DataURLImageDecoder {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // data URL 已经同时存在于消息模型中，缓存只保留有限的解码结果，避免长会话内存持续增长。
        cache.totalCostLimit = 48 * 1_024 * 1_024
        cache.countLimit = 32
        return cache
    }()

    static func image(
        from value: String,
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) async -> UIImage? {
        guard !Task.isCancelled else {
            return nil
        }
        let boundedPixelSize = max(1, maxPixelSize)
        let resolvedCacheKey = Self.resolvedCacheKey(
            kind: "data",
            profileID: profileID,
            cacheKey: cacheKey,
            maxPixelSize: boundedPixelSize
        )
        if let cached = cache.object(forKey: resolvedCacheKey) {
            return cached
        }
        await Task.yield()
        guard !Task.isCancelled else {
            return nil
        }

        let decodeTask = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let data = decodedData(from: value),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else {
                return nil
            }

            guard !Task.isCancelled else {
                return nil
            }
            let image = UIImage(cgImage: cgImage)
            let cost = cgImage.bytesPerRow * cgImage.height
            cache.setObject(image, forKey: resolvedCacheKey, cost: cost)
            return image
        }
        // `.task(id:)` 被新来源替换或视图消失时，把取消继续传给后台解码，避免无效图片继续占 CPU。
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    static func image(
        fromFileURL url: URL,
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) async -> UIImage? {
        guard !Task.isCancelled else {
            return nil
        }
        let boundedPixelSize = max(1, maxPixelSize)
        let resolvedCacheKey = Self.resolvedCacheKey(
            kind: "file",
            profileID: profileID,
            cacheKey: cacheKey,
            maxPixelSize: boundedPixelSize
        )
        if let cached = cache.object(forKey: resolvedCacheKey) {
            return cached
        }

        let decodeTask = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else {
                return nil
            }
            let image = UIImage(cgImage: cgImage)
            cache.setObject(
                image,
                forKey: resolvedCacheKey,
                cost: cgImage.bytesPerRow * cgImage.height
            )
            return image
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    /// 只读取已解码缓存，不在 SwiftUI 初始化或 `body` 路径执行 Base64/ImageIO 工作。
    static func cachedImage(
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) -> UIImage? {
        let boundedPixelSize = max(1, maxPixelSize)
        return cache.object(
            forKey: Self.resolvedCacheKey(
                kind: "data",
                profileID: profileID,
                cacheKey: cacheKey,
                maxPixelSize: boundedPixelSize
            )
        )
    }

#if DEBUG
    static func removeAllCachedImagesForTesting() {
        cache.removeAllObjects()
    }
#endif

    private static func decodedData(from value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil,
              let comma = trimmed.firstIndex(of: ",")
        else {
            return nil
        }
        let payload = trimmed[trimmed.index(after: comma)...]
        return Data(base64Encoded: String(payload), options: [.ignoreUnknownCharacters])
    }

    private static func resolvedCacheKey(
        kind: String,
        profileID: String,
        cacheKey: String,
        maxPixelSize: Int
    ) -> NSString {
        let identity = MediaRequestIdentity(
            profileID: profileID,
            resourceID: cacheKey
        )
        // 长度前缀避免 Profile/资源字符串含分隔符时发生组合键碰撞；只存在进程内，不落盘。
        return "\(identity.profileID.utf8.count):\(identity.profileID):\(kind):\(cacheKey):\(maxPixelSize)" as NSString
    }
}
