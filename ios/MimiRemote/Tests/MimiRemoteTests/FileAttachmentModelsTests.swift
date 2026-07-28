import XCTest
@testable import MimiRemote

final class FileAttachmentModelsTests: XCTestCase {
    func testFileImporterKeepsRequestUntilResultCallbackAfterDismissal() {
        let request = FileImporterRequest(
            targetScope: .session("session-1")
        )
        var presentation = FileImporterPresentationState()

        presentation.present(request)
        XCTAssertTrue(presentation.isPresented)

        // 模拟 SwiftUI 的真实顺序：选择器先关闭，结果回调随后才执行。
        presentation.isPresented = false
        XCTAssertEqual(presentation.request, request)
        XCTAssertEqual(presentation.consumeRequest(), request)
        XCTAssertNil(presentation.request)
        XCTAssertFalse(presentation.isPresented)
    }

    func testUploadedFilePersistsAsLocalOnlyInputType() throws {
        let file = makeFile()
        let input = CodexAppServerUserInput.uploadedFile(file)

        let data = try JSONEncoder().encode(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "uploadedFile")

        let restored = try JSONDecoder().decode(CodexAppServerUserInput.self, from: data)
        XCTAssertEqual(restored, input)
    }

    func testAppServerPayloadExpandsFileIntoSupportedTextAndImageInputs() throws {
        let file = makeFile(pageImageDataURLs: [
            "data:image/jpeg;base64,AA==",
            "data:image/jpeg;base64,BB=="
        ])
        let payload = CodexAppServerTurnPayload(input: [
            .text("总结附件"),
            .uploadedFile(file)
        ])

        let values = try XCTUnwrap(payload.appServerInput.arrayValue)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values[0].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(values[1].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(values[2].objectValue?["type"]?.stringValue, "image")
        XCTAssertEqual(values[3].objectValue?["type"]?.stringValue, "image")
        XCTAssertFalse(values.contains {
            $0.objectValue?["type"]?.stringValue == "uploadedFile"
        })
        XCTAssertLessThan(payload.encodedAppServerInputByteCount, CodexAppServerTurnPayload.maximumEncodedInputBytes)
    }

    func testHistoryCollapseRestoresFileWithoutExposingInternalContextText() throws {
        let file = makeFile(pageImageDataURLs: ["data:image/jpeg;base64,AA=="])
        var expanded = MimiFileContextCodec.expandedInputs(for: file)
        // agentd 会把历史中的 data URL 外置成短地址；恢复时仍应归回文件附件。
        expanded[1] = .image(url: "agentd-history-media://page-1", detail: .auto)

        let collapsed = MimiFileContextCodec.collapsingExpandedInputs(expanded)
        guard case .uploadedFile(let restored) = try XCTUnwrap(collapsed.first) else {
            return XCTFail("Expected restored file attachment")
        }
        XCTAssertEqual(restored.uploadID, file.uploadID)
        XCTAssertEqual(restored.pageImageDataURLs, ["agentd-history-media://page-1"])
        XCTAssertEqual(collapsed.first?.previewText, "notes.pdf")
        XCTAssertFalse(collapsed.first?.previewText.contains("mimi_file_context") ?? true)
        XCTAssertFalse(collapsed.first?.previewText.contains("<file_content>") ?? true)
    }

    func testHistoryCollapseRejectsMismatchedStructuredMarker() throws {
        let file = makeFile()
        guard case .text(let text, _) = MimiFileContextCodec.contextInput(for: file) else {
            return XCTFail("Expected internal text context")
        }
        let mismatched = CodexAppServerUserInput.text(
            text,
            textElements: [
                .object([
                    "type": .string("mimi_file_context"),
                    "version": .int(1),
                    "upload_id": .string("another-upload"),
                    "page_image_count": .int(0)
                ])
            ]
        )

        XCTAssertEqual(MimiFileContextCodec.collapsingExpandedInputs([mismatched]), [mismatched])
    }

    func testVersionResponseTreatsMissingCapabilitiesAsLegacyServer() throws {
        let legacy = try AgentAPIClient.decoder.decode(
            VersionResponse.self,
            from: Data(#"{"name":"agentd","version":"1.0.0"}"#.utf8)
        )
        XCTAssertEqual(legacy.capabilities, [])

        let current = try AgentAPIClient.decoder.decode(
            VersionResponse.self,
            from: Data(#"{"name":"agentd","version":"1.1.0","installation_id":"mac-installation","capabilities":["file_upload_v1"]}"#.utf8)
        )
        XCTAssertEqual(current.installationID, "mac-installation")
        XCTAssertEqual(current.capabilities, ["file_upload_v1"])
    }

    func testTextFilePreparationUsesBoundedUTF8PreviewAndPrivateStagingCopy() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-file-test-\(UUID().uuidString).md")
        try Data(repeating: 0x61, count: FileAttachmentPreparer.maximumExtractedTextBytes + 512)
            .write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = try await FileAttachmentPreparer.prepare(selectedURL: source)
        defer { prepared.removeStagingFiles() }

        XCTAssertEqual(prepared.name, source.lastPathComponent)
        XCTAssertEqual(prepared.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(prepared.extractedText.utf8.count, FileAttachmentPreparer.maximumExtractedTextBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertNotEqual(prepared.fileURL, source)
    }

    func testFilePreparationRejectsUnsupportedExtension() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-file-test-\(UUID().uuidString).zip")
        try Data("not a supported archive".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await FileAttachmentPreparer.prepare(selectedURL: source)
            XCTFail("Expected unsupported file error")
        } catch let error as FileAttachmentPreparationError {
            guard case .unsupported = error else {
                return XCTFail("Unexpected preparation error: \(error)")
            }
        }
    }

    private func makeFile(pageImageDataURLs: [String] = []) -> UploadedFileAttachment {
        UploadedFileAttachment(
            uploadID: "upload-1",
            name: "notes.pdf",
            contentType: "application/pdf",
            size: 1_024,
            sha256: String(repeating: "a", count: 64),
            downloadPath: "/api/file-uploads/upload-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_604_800),
            extractedText: "第一段\n第二段",
            pageImageDataURLs: pageImageDataURLs
        )
    }
}
