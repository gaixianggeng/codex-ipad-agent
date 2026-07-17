import Foundation
import ImageIO
import UIKit

struct PreparedImageAttachment: Sendable, Equatable {
    let dataURL: String
    let encodedByteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ImageAttachmentEncodingError: LocalizedError {
    case emptyData
    case inputTooLarge
    case unsupportedImage
    case jpegEncodingFailed
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "图片内容为空"
        case .inputTooLarge:
            return "原始图片超过 50 MB，请先裁剪后再试"
        case .unsupportedImage:
            return "图片格式无法读取"
        case .jpegEncodingFailed:
            return "图片压缩失败"
        case .outputTooLarge:
            return "图片压缩后仍超过 2 MB，请先裁剪后再试"
        }
    }
}

enum ImageAttachmentEncoder {
    static let maximumInputByteCount = 50 * 1_024 * 1_024
    static let maximumPixelDimension = 1_600
    static let targetEncodedByteCount = 2 * 1_024 * 1_024

    nonisolated static func prepare(_ data: Data) throws -> PreparedImageAttachment {
        guard !data.isEmpty else {
            throw ImageAttachmentEncodingError.emptyData
        }
        guard data.count <= maximumInputByteCount else {
            throw ImageAttachmentEncodingError.inputTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageAttachmentEncodingError.unsupportedImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageAttachmentEncodingError.unsupportedImage
        }

        let size = CGSize(width: thumbnail.width, height: thumbnail.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // JPEG 不支持透明通道；统一白底，避免透明 PNG 转码后出现黑色背景。
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: size))
        }

        var encoded: Data?
        // 普通截图通常第一档就小于 2 MB；高噪声照片逐级降质量，控制 base64/WebSocket 体积。
        for quality in [0.80, 0.68, 0.56] {
            encoded = normalized.jpegData(compressionQuality: quality)
            if let encoded, encoded.count <= targetEncodedByteCount {
                break
            }
        }
        guard let encoded else {
            throw ImageAttachmentEncodingError.jpegEncodingFailed
        }
        guard encoded.count <= targetEncodedByteCount else {
            throw ImageAttachmentEncodingError.outputTooLarge
        }

        return PreparedImageAttachment(
            dataURL: "data:image/jpeg;base64,\(encoded.base64EncodedString())",
            encodedByteCount: encoded.count,
            pixelWidth: thumbnail.width,
            pixelHeight: thumbnail.height
        )
    }
}
