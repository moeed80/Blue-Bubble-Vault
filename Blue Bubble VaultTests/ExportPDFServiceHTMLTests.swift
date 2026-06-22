import AppKit
import XCTest
@testable import Blue_Bubble_Vault

@MainActor
final class ExportPDFServiceHTMLTests: XCTestCase {
    private let syntheticThread = ChatThread(
        chatID: 77,
        guid: "synthetic-thread-guid",
        chatIdentifier: "+15550192834",
        displayName: "",
        messageCount: 2,
        participantHandles: "+15550192834, analyst@example.test"
    )

    private let syntheticContext = ExportRenderContext(
        threadTitle: "Synthetic Alice",
        sourceDisplayName: "Synthetic Fixture",
        resolvedNames: [
            "+15550192834": "Alice Fixture",
            "analyst@example.test": "Archive Analyst"
        ],
        evidenceCustodian: "Fixture Custodian",
        hostName: "Fixture Host"
    )

    func testExportEngineDescriptionIncludesVersionAndBuild() {
        let description = ExportPDFService.shared.exportEngineDescription(version: "1.0", build: "1")

        XCTAssertEqual(description, "Blue Bubble Vault 1.0 (Build 1)")
    }

    func testExportEngineDescriptionFallsBackToAppNameWhenVersionIsUnavailable() {
        let description = ExportPDFService.shared.exportEngineDescription(version: " ", build: nil)

        XCTAssertEqual(description, "Blue Bubble Vault")
    }

    func testCSVEscapingHandlesQuotesCommasAndNewlines() {
        let escaped = ExportPDFService.shared.csvEscape("Hello, \"world\"\nNext line")

        XCTAssertEqual(escaped, "\"Hello, \"\"world\"\"\nNext line\"")
    }

    func testBuildCSVUsesEscapedRowsAndAttachmentStatus() {
        let messages = [
            MessageItem(
                messageID: 1,
                text: "Please review, then say \"yes\".\nThanks",
                date: Date(timeIntervalSinceReferenceDate: 2_000),
                isFromMe: false,
                senderID: "+15550192834",
                attachments: [
                    AttachmentItem(
                        attachmentID: 500,
                        guid: "synthetic-attachment-guid",
                        filename: "/SyntheticFixtures/missing-contract.pdf",
                        mimeType: "application/pdf",
                        totalBytes: 42
                    )
                ]
            )
        ]
        let attachmentRecords = [
            ExportAttachmentRecord(
                messageID: 1,
                attachmentID: 500,
                originalFilename: "missing-contract.pdf",
                copiedFilename: nil,
                byteSize: 42,
                mimeType: "application/pdf",
                status: "missing"
            )
        ]

        let csv = ExportPDFService.shared.buildCSV(
            for: syntheticThread,
            messages: messages,
            context: syntheticContext,
            attachmentRecords: attachmentRecords
        )

        XCTAssertTrue(csv.contains("\"Please review, then say \"\"yes\"\".\nThanks\""))
        XCTAssertTrue(csv.contains("missing-contract.pdf,missing"))
        XCTAssertEqual(csv.split(separator: "\n", omittingEmptySubsequences: false).count, 4)
    }

    func testSHA256HashingForGeneratedFileData() {
        let data = Data("abc".utf8)

        XCTAssertEqual(
            ExportPDFService.sha256HexDigest(for: data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testManifestGenerationIsDeterministicForStableInputs() throws {
        let messages = [
            MessageItem(
                messageID: 1,
                text: "Confirmed.",
                date: Date(timeIntervalSinceReferenceDate: 2_060),
                isFromMe: true,
                senderID: "me",
                attachments: []
            )
        ]
        let filters = ExportFilterSnapshot(
            dateMode: "Select Date Range",
            startDate: Date(timeIntervalSinceReferenceDate: 1_000),
            endDate: Date(timeIntervalSinceReferenceDate: 3_000),
            keyword: "confirmed",
            includeMedia: true
        )
        let outputFiles = [
            ExportOutputFileRecord(role: "pdf", filename: "thread.pdf", byteSize: 10, sha256: "abc"),
            ExportOutputFileRecord(role: "csv", filename: "thread.csv", byteSize: 5, sha256: "def")
        ]
        let attachments = [
            ExportAttachmentRecord(
                messageID: 1,
                attachmentID: 500,
                originalFilename: "photo.jpg",
                copiedFilename: "thread_attachments/message-1-attachment-500-photo.jpg",
                byteSize: 4096,
                mimeType: "image/jpeg",
                status: "copied"
            )
        ]
        let createdAt = Date(timeIntervalSinceReferenceDate: 4_000)

        let first = try ExportPDFService.shared.buildManifestData(
            thread: syntheticThread,
            messages: messages,
            context: syntheticContext,
            filters: filters,
            outputFiles: outputFiles,
            attachments: attachments,
            createdAt: createdAt
        )
        let second = try ExportPDFService.shared.buildManifestData(
            thread: syntheticThread,
            messages: messages,
            context: syntheticContext,
            filters: filters,
            outputFiles: Array(outputFiles.reversed()),
            attachments: attachments,
            createdAt: createdAt
        )

        XCTAssertEqual(first, second)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: first)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.thread.guid, "synthetic-thread-guid")
        XCTAssertEqual(manifest.exportedMessageCount, 1)
        XCTAssertEqual(manifest.outputFiles.map(\.filename), ["thread.csv", "thread.pdf"])
        XCTAssertEqual(manifest.attachments.first?.status, "copied")
    }

    func testMissingAttachmentHandlingDoesNotFailMetadataGeneration() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueBubbleVaultExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let messages = [
            MessageItem(
                messageID: 1,
                text: "Missing synthetic attachment.",
                date: Date(timeIntervalSinceReferenceDate: 2_000),
                isFromMe: false,
                senderID: "+15550192834",
                attachments: [
                    AttachmentItem(
                        attachmentID: 500,
                        guid: "missing-guid",
                        filename: "/SyntheticFixtures/missing-photo.jpg",
                        mimeType: "image/jpeg",
                        totalBytes: 4096
                    )
                ]
            )
        ]

        let result = try ExportPDFService.shared.copyAvailableAttachments(
            for: messages,
            attachmentsDirectoryURL: temporaryDirectory.appendingPathComponent("attachments", isDirectory: true),
            includeMedia: true
        )

        XCTAssertNil(result.attachmentsDirectoryURL)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.originalFilename, "missing-photo.jpg")
        XCTAssertEqual(result.records.first?.status, "missing")
    }

    func testBuildHTMLEscapesMessageContentAndUsesFakeRenderContext() {
        let messages = [
            MessageItem(
                messageID: 1,
                text: "Please review <contract> & confirm \"yes\".",
                date: Date(timeIntervalSinceReferenceDate: 2_000),
                isFromMe: false,
                senderID: "+15550192834",
                attachments: []
            ),
            MessageItem(
                messageID: 2,
                text: "Confirmed.",
                date: Date(timeIntervalSinceReferenceDate: 2_060),
                isFromMe: true,
                senderID: "me",
                attachments: []
            )
        ]

        let html = ExportPDFService.shared.buildHTML(for: syntheticThread, messages: messages, context: syntheticContext)

        XCTAssertTrue(html.contains("Synthetic Alice"))
        XCTAssertTrue(html.contains("Synthetic Fixture"))
        XCTAssertTrue(html.contains("Fixture Custodian"))
        XCTAssertTrue(html.contains("Fixture Host"))
        XCTAssertTrue(html.contains("Alice Fixture"))
        XCTAssertTrue(html.contains("Archive Analyst"))
        XCTAssertTrue(html.contains("id=\"pdf-pages\""))
        XCTAssertTrue(html.contains("window.__BBV_PAGINATED__ = true"))
        XCTAssertTrue(html.contains("appendWholeBlock"))
        XCTAssertTrue(html.contains("setTimeout(paginateExport, 0)"))
        XCTAssertTrue(html.contains("Please review &lt;contract&gt; &amp; confirm &quot;yes&quot;."))
        XCTAssertTrue(html.contains("message-77-1"))
        XCTAssertTrue(html.contains("message-77-2"))
        XCTAssertFalse(html.contains("Please review <contract> & confirm \"yes\"."))
    }

    func testPaginatedA4PDFDataSlicesTallPDFIntoA4Pages() throws {
        let tallPDFData = try makeTallPDFData(width: 595, height: 1_684)

        let paginatedData = try ExportPDFService.paginatedA4PDFData(from: tallPDFData)

        guard let provider = CGDataProvider(data: paginatedData as CFData),
              let document = CGPDFDocument(provider),
              let firstPage = document.page(at: 1),
              let secondPage = document.page(at: 2) else {
            return XCTFail("Expected a readable multi-page PDF.")
        }

        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertEqual(firstPage.getBoxRect(.mediaBox).width, 595, accuracy: 0.5)
        XCTAssertEqual(firstPage.getBoxRect(.mediaBox).height, 842, accuracy: 0.5)
        XCTAssertEqual(secondPage.getBoxRect(.mediaBox).width, 595, accuracy: 0.5)
        XCTAssertEqual(secondPage.getBoxRect(.mediaBox).height, 842, accuracy: 0.5)
    }

    private func makeTallPDFData(width: CGFloat, height: CGFloat) throws -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)

        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportPDFError.invalidPDFData
        }

        context.beginPDFPage(nil)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 40, y: height - 120, width: 160, height: 60))
        context.setFillColor(NSColor.darkGray.cgColor)
        context.fill(CGRect(x: 40, y: 40, width: 160, height: 60))
        context.endPDFPage()
        context.closePDF()

        return output as Data
    }
}
