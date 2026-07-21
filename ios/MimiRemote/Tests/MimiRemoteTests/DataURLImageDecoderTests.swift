import XCTest
import UIKit
@testable import MimiRemote

@MainActor
final class DataURLImageDecoderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DataURLImageDecoder.removeAllCachedImagesForTesting()
    }

    func testDataURLImageDecoderDecodesValidImageAndRejectsInvalidPayloads() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 120, height: 80), color: .systemBlue)

        let image = await DataURLImageDecoder.image(from: dataURL, cacheKey: "valid", maxPixelSize: 256)
        let textPayload = await DataURLImageDecoder.image(from: "data:text/plain;base64,SGVsbG8=", cacheKey: "text", maxPixelSize: 256)
        let invalidPayload = await DataURLImageDecoder.image(from: "data:image/png;base64,not-base64", cacheKey: "invalid", maxPixelSize: 256)

        XCTAssertNotNil(image)
        XCTAssertNil(textPayload)
        XCTAssertNil(invalidPayload)
    }

    func testDataURLImageDecoderReusesCachedImageForStableKey() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 96, height: 64), color: .systemGreen)
        let firstResult = await DataURLImageDecoder.image(from: dataURL, cacheKey: "stable-digest", maxPixelSize: 256)
        let secondResult = await DataURLImageDecoder.image(from: dataURL, cacheKey: "stable-digest", maxPixelSize: 256)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertTrue(first === second)
    }

    func testDataURLImageDecoderDownsamplesWithoutChangingAspectRatio() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 800, height: 400), color: .systemOrange)

        let result = await DataURLImageDecoder.image(from: dataURL, cacheKey: "scaled", maxPixelSize: 100)
        let image = try XCTUnwrap(result)

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 100)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.05)
    }

    func testDataURLImageDecoderHonorsTaskCancellation() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 1_024, height: 1_024), color: .systemPurple)
        let task = Task {
            await DataURLImageDecoder.image(from: dataURL, cacheKey: "cancelled", maxPixelSize: 1_024)
        }

        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
    }

    func testFileImageDecoderDownsamplesPreviewAndReusesSharedCache() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-image-decoder-\(UUID().uuidString).png")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = await DataURLImageDecoder.image(fromFileURL: url, cacheKey: "file-preview", maxPixelSize: 100)
        let second = await DataURLImageDecoder.image(fromFileURL: url, cacheKey: "file-preview", maxPixelSize: 100)
        let decoded = try XCTUnwrap(first)

        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 100)
        XCTAssertTrue(decoded === second)
    }

    func testDataURLImageDecoderRapidSourceSwitchDiscardsCancelledResult() async throws {
        let firstURL = try makeDataURL(size: CGSize(width: 1_024, height: 768), color: .systemRed)
        let secondURL = try makeDataURL(size: CGSize(width: 160, height: 90), color: .systemTeal)
        let firstTask = Task {
            await DataURLImageDecoder.image(from: firstURL, cacheKey: "source-a", maxPixelSize: 1_024)
        }
        firstTask.cancel()

        let second = await DataURLImageDecoder.image(from: secondURL, cacheKey: "source-b", maxPixelSize: 320)
        let cancelledFirst = await firstTask.value

        XCTAssertNil(cancelledFirst)
        XCTAssertNotNil(second)
    }

    private func makeDataURL(size: CGSize, color: UIColor) throws -> String {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let data = try XCTUnwrap(image.pngData())
        return "data:image/png;base64,\(data.base64EncodedString())"
    }
}
