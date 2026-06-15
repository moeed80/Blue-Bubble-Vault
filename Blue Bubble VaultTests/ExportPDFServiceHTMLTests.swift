import AppKit
import XCTest
@testable import Blue_Bubble_Vault

@MainActor
final class ExportPDFServiceHTMLTests: XCTestCase {
    func testBuildHTMLEscapesMessageContentAndUsesFakeRenderContext() {
        let thread = ChatThread(
            chatID: 77,
            guid: "synthetic-thread-guid",
            chatIdentifier: "+15550192834",
            displayName: "",
            messageCount: 2,
            participantHandles: "+15550192834, analyst@example.test"
        )
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
        let context = ExportRenderContext(
            threadTitle: "Synthetic Alice",
            sourceDisplayName: "Synthetic Fixture",
            resolvedNames: [
                "+15550192834": "Alice Fixture",
                "analyst@example.test": "Archive Analyst"
            ],
            evidenceCustodian: "Fixture Custodian",
            hostName: "Fixture Host"
        )

        let html = ExportPDFService.shared.buildHTML(for: thread, messages: messages, context: context)

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
