import AppKit
import CryptoKit
import Foundation
import WebKit
import CoreGraphics

struct ExportRenderContext {
    let threadTitle: String
    let sourceDisplayName: String
    let resolvedNames: [String: String]
    let evidenceCustodian: String
    let hostName: String

    init(threadTitle: String,
         sourceDisplayName: String,
         resolvedNames: [String: String],
         evidenceCustodian: String = "[unassigned]",
         hostName: String = ExportRenderContext.defaultHostName()) {
        self.threadTitle = threadTitle
        self.sourceDisplayName = sourceDisplayName
        self.resolvedNames = resolvedNames
        self.evidenceCustodian = evidenceCustodian
        self.hostName = hostName
    }

    private static func defaultHostName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return host.isEmpty ? "Local macOS Host" : host
    }
}

struct ExportFilterSnapshot: Equatable {
    let dateMode: String
    let startDate: Date?
    let endDate: Date?
    let keyword: String?
    let includeMedia: Bool
}

struct ExportPackageResult {
    let packageDirectoryURL: URL
    let pdfURL: URL
    let htmlURL: URL
    let csvURL: URL
    let manifestURL: URL
    let attachmentsDirectoryURL: URL?
    let copiedAttachmentCount: Int
    let missingAttachmentCount: Int
}

struct ExportAttachmentRecord: Codable, Equatable {
    let messageID: Int64
    let attachmentID: Int64
    let originalFilename: String
    let copiedFilename: String?
    let byteSize: Int64
    let mimeType: String
    let status: String
}

struct ExportOutputFileRecord: Codable, Equatable {
    let role: String
    let filename: String
    let byteSize: Int64
    let sha256: String
}

struct ExportManifest: Codable, Equatable {
    let schemaVersion: Int
    let exportEngine: String
    let createdAt: String
    let sourceDisplayName: String
    let thread: ExportManifestThread
    let filters: ExportManifestFilters
    let exportedMessageCount: Int
    let outputFiles: [ExportOutputFileRecord]
    let attachments: [ExportAttachmentRecord]
}

struct ExportManifestThread: Codable, Equatable {
    let chatID: Int64
    let title: String
    let identifier: String
    let guid: String
}

struct ExportManifestFilters: Codable, Equatable {
    let dateMode: String
    let startDate: String?
    let endDate: String?
    let keyword: String?
    let includeMedia: Bool
}

struct AttachmentCopyResult {
    let records: [ExportAttachmentRecord]
    let attachmentsDirectoryURL: URL?
}

/// Exports a selected conversation as a local package: an A4 PDF, diagnostic HTML,
/// CSV rows, and a deterministic manifest JSON sidecar.
final class ExportPDFService {
    /// Shared singleton instance of the export service.
    static let shared = ExportPDFService()

    /// A4 page size in PDF points at 72 points per inch: 8.27 x 11.69 inches.
    private static let a4PageRect = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// Strong reference to the active `WKWebView` instance during an on-going PDF generation process.
    /// This prevents ARC (Automatic Reference Counting) from garbage-collecting the web view mid-render
    /// while the asynchronous layout engine compiles the document's geometry.
    @MainActor private var activeWebView: WKWebView?

    /// Exports a chat thread's message history to a PDF file at a user-specified destination URL.
    ///
    /// Compatibility entry point for callers that only need the generated PDF path. The export
    /// still writes the v1 package sidecars next to the PDF.
    ///
    /// - Parameters:
    ///   - outputURL: The desired filesystem URL where the compiled PDF should be written.
    ///   - thread: The chat thread metadata (e.g. Chat ID, Guid, mapped participants).
    ///   - messages: The array of extracted messages belonging to the conversation thread.
    ///   - appState: The global application state object (used for title and identity resolution).
    /// - Returns: The filesystem URL of the successfully generated PDF document.
    @MainActor
    func exportThread(to outputURL: URL,
                      thread: ChatThread,
                      messages: [MessageItem],
                      appState: AppState) async throws -> URL {
        let result = try await exportThreadPackage(to: outputURL, thread: thread, messages: messages, appState: appState)
        return result.pdfURL
    }

    /// Asynchronous alias of `exportThread`.
    @MainActor
    func exportThreadAsync(to outputURL: URL,
                           thread: ChatThread,
                           messages: [MessageItem],
                           appState: AppState) async throws -> URL {
        let result = try await exportThreadPackage(to: outputURL, thread: thread, messages: messages, appState: appState)
        return result.pdfURL
    }

    @MainActor
    func exportThreadPackage(to outputURL: URL,
                             thread: ChatThread,
                             messages: [MessageItem],
                             appState: AppState,
                             createdAt: Date = Date()) async throws -> ExportPackageResult {
        let requestedFolderURL = normalizedExportFolderURL(from: outputURL)
        let packageDirectoryURL = try createPackageDirectory(at: requestedFolderURL)
        let baseName = packageDirectoryURL.lastPathComponent
        let pdfURL = packageDirectoryURL.appendingPathComponent("\(baseName).pdf")
        let htmlURL = packageDirectoryURL.appendingPathComponent("\(baseName).render.html")
        let csvURL = packageDirectoryURL.appendingPathComponent("\(baseName).csv")
        let manifestURL = packageDirectoryURL.appendingPathComponent("\(baseName).manifest.json")
        let requestedAttachmentsDirectoryURL = packageDirectoryURL.appendingPathComponent("attachments", isDirectory: true)

        let orderedMessages = messages.sorted { $0.date < $1.date }
        let context = appState.exportRenderContext(for: thread)
        let filters = appState.exportFilterSnapshot()
        let html = buildHTML(for: thread, messages: orderedMessages, context: context)

        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        try await renderHTMLAsync(html, to: pdfURL)

        let attachmentCopyResult = try copyAvailableAttachments(
            for: orderedMessages,
            attachmentsDirectoryURL: requestedAttachmentsDirectoryURL,
            includeMedia: filters.includeMedia
        )
        let csv = buildCSV(
            for: thread,
            messages: orderedMessages,
            context: context,
            attachmentRecords: attachmentCopyResult.records
        )
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        var filesForHashing: [(role: String, url: URL)] = [
            ("pdf", pdfURL),
            ("csv", csvURL),
            ("diagnostic_html", htmlURL)
        ]

        for record in attachmentCopyResult.records where record.status == "copied" {
            guard let copiedFilename = record.copiedFilename else { continue }
            filesForHashing.append(("attachment", packageDirectoryURL.appendingPathComponent(copiedFilename)))
        }

        let outputFiles = try buildOutputFileRecords(for: filesForHashing, relativeTo: packageDirectoryURL)
        let manifestData = try buildManifestData(
            thread: thread,
            messages: orderedMessages,
            context: context,
            filters: filters,
            outputFiles: outputFiles,
            attachments: attachmentCopyResult.records,
            createdAt: createdAt
        )
        try manifestData.write(to: manifestURL, options: .atomic)

        return ExportPackageResult(
            packageDirectoryURL: packageDirectoryURL,
            pdfURL: pdfURL,
            htmlURL: htmlURL,
            csvURL: csvURL,
            manifestURL: manifestURL,
            attachmentsDirectoryURL: attachmentCopyResult.attachmentsDirectoryURL,
            copiedAttachmentCount: attachmentCopyResult.records.filter { $0.status == "copied" }.count,
            missingAttachmentCount: attachmentCopyResult.records.filter { $0.status != "copied" }.count
        )
    }

    /// Automatically generates a structured default filename for exports,
    /// encoding the participant label and message date span.
    func defaultFileName(for thread: ChatThread, messages: [MessageItem], appState: AppState) -> String {
        let context = appState.exportRenderContext(for: thread)
        let participants = participantSummary(for: thread, messages: messages, context: context)
        let threadLabel = participants.isEmpty ? context.threadTitle : participants
        let startDate = messages.first?.date ?? Date()
        let endDate = messages.last?.date ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"

        let safeThreadLabel = sanitizeFileNameComponent(threadLabel)
        let safeStart = formatter.string(from: startDate)
        let safeEnd = formatter.string(from: endDate)
        let prefix = safeThreadLabel.isEmpty ? "conversation" : safeThreadLabel
        return "\(prefix)_\(safeStart)_to_\(safeEnd).pdf"
    }

    func defaultFolderName(for thread: ChatThread, messages: [MessageItem], appState: AppState) -> String {
        let fileName = defaultFileName(for: thread, messages: messages, appState: appState)
        return (fileName as NSString).deletingPathExtension
    }

    /// Identifies the app build that generated the export.
    func exportEngineDescription(
        version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ) -> String {
        let cleanVersion = nonEmptyVersionComponent(version)
        let cleanBuild = nonEmptyVersionComponent(build)

        switch (cleanVersion, cleanBuild) {
        case let (version?, build?):
            return "Blue Bubble Vault \(version) (Build \(build))"
        case let (version?, nil):
            return "Blue Bubble Vault \(version)"
        case let (nil, build?):
            return "Blue Bubble Vault (Build \(build))"
        case (nil, nil):
            return "Blue Bubble Vault"
        }
    }

    func buildCSV(for thread: ChatThread,
                  messages: [MessageItem],
                  context: ExportRenderContext,
                  attachmentRecords: [ExportAttachmentRecord]) -> String {
        let recordsByMessage = Dictionary(grouping: attachmentRecords, by: \.messageID)
        let header = [
            "message_id",
            "timestamp",
            "direction",
            "sender_id",
            "resolved_sender_display_name",
            "message_text",
            "attachment_count",
            "attachment_filenames",
            "attachment_statuses",
            "source_display_name",
            "thread_identifier",
            "thread_guid"
        ]

        let rows = messages.map { message -> [String] in
            let records = recordsByMessage[message.messageID] ?? []
            let direction = message.isFromMe ? "sent" : "received"
            let senderDisplayName = resolveDisplayName(for: message, thread: thread, context: context)
            let filenames = records.map(\.originalFilename).joined(separator: "; ")
            let statuses = records.map(\.status).joined(separator: "; ")

            return [
                String(message.messageID),
                Self.iso8601String(from: message.date),
                direction,
                message.senderID,
                senderDisplayName,
                message.text,
                String(message.attachments.count),
                filenames,
                statuses,
                context.sourceDisplayName,
                thread.chatIdentifier,
                thread.guid
            ]
        }

        let allRows = [header] + rows
        return allRows
            .map { fields in fields.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }

        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    func copyAvailableAttachments(for messages: [MessageItem],
                                  attachmentsDirectoryURL: URL,
                                  includeMedia: Bool,
                                  fileManager: FileManager = .default) throws -> AttachmentCopyResult {
        guard includeMedia else {
            return AttachmentCopyResult(records: [], attachmentsDirectoryURL: nil)
        }

        var records: [ExportAttachmentRecord] = []
        var createdAttachmentsDirectory = false

        for message in messages {
            for attachment in message.attachments {
                let originalFilename = originalFilename(for: attachment)
                let byteSize = attachmentByteSize(for: attachment, fileManager: fileManager)

                guard let sourceURL = attachment.fileURL,
                      fileManager.fileExists(atPath: sourceURL.path) else {
                    records.append(ExportAttachmentRecord(
                        messageID: message.messageID,
                        attachmentID: attachment.attachmentID,
                        originalFilename: originalFilename,
                        copiedFilename: nil,
                        byteSize: byteSize,
                        mimeType: attachment.mimeType,
                        status: "missing"
                    ))
                    continue
                }

                if !createdAttachmentsDirectory {
                    try fileManager.createDirectory(at: attachmentsDirectoryURL, withIntermediateDirectories: true)
                    createdAttachmentsDirectory = true
                }

                let copiedName = copiedAttachmentFilename(for: attachment, messageID: message.messageID)
                let destinationURL = attachmentsDirectoryURL.appendingPathComponent(copiedName)
                let relativeCopiedName = "\(attachmentsDirectoryURL.lastPathComponent)/\(copiedName)"

                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    records.append(ExportAttachmentRecord(
                        messageID: message.messageID,
                        attachmentID: attachment.attachmentID,
                        originalFilename: originalFilename,
                        copiedFilename: relativeCopiedName,
                        byteSize: byteSize,
                        mimeType: attachment.mimeType,
                        status: "copied"
                    ))
                } catch {
                    records.append(ExportAttachmentRecord(
                        messageID: message.messageID,
                        attachmentID: attachment.attachmentID,
                        originalFilename: originalFilename,
                        copiedFilename: nil,
                        byteSize: byteSize,
                        mimeType: attachment.mimeType,
                        status: "unavailable"
                    ))
                }
            }
        }

        return AttachmentCopyResult(
            records: records,
            attachmentsDirectoryURL: createdAttachmentsDirectory ? attachmentsDirectoryURL : nil
        )
    }

    func buildManifestData(thread: ChatThread,
                           messages: [MessageItem],
                           context: ExportRenderContext,
                           filters: ExportFilterSnapshot,
                           outputFiles: [ExportOutputFileRecord],
                           attachments: [ExportAttachmentRecord],
                           createdAt: Date) throws -> Data {
        let manifest = ExportManifest(
            schemaVersion: 1,
            exportEngine: exportEngineDescription(),
            createdAt: Self.iso8601String(from: createdAt),
            sourceDisplayName: context.sourceDisplayName,
            thread: ExportManifestThread(
                chatID: thread.chatID,
                title: context.threadTitle,
                identifier: thread.chatIdentifier,
                guid: thread.guid
            ),
            filters: ExportManifestFilters(
                dateMode: filters.dateMode,
                startDate: filters.startDate.map { Self.iso8601String(from: $0) },
                endDate: filters.endDate.map { Self.iso8601String(from: $0) },
                keyword: filters.keyword,
                includeMedia: filters.includeMedia
            ),
            exportedMessageCount: messages.count,
            outputFiles: outputFiles.sorted { $0.filename < $1.filename },
            attachments: attachments.sorted {
                if $0.messageID == $1.messageID {
                    return $0.attachmentID < $1.attachmentID
                }
                return $0.messageID < $1.messageID
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    func buildOutputFileRecords(for files: [(role: String, url: URL)],
                                relativeTo baseURL: URL) throws -> [ExportOutputFileRecord] {
        try files.map { file in
            let data = try Data(contentsOf: file.url)
            let relativeFilename = relativePath(from: baseURL, to: file.url)
            return ExportOutputFileRecord(
                role: file.role,
                filename: relativeFilename,
                byteSize: Int64(data.count),
                sha256: Self.sha256HexDigest(for: data)
            )
        }
    }

    static func sha256HexDigest(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Assembles raw thread structures and message objects into a monolithic HTML string.
    /// This includes writing the layout style block, the export summary cover,
    /// a participant list, and the itemized conversation stream.
    func buildHTML(for thread: ChatThread,
                   messages: [MessageItem],
                   context: ExportRenderContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Build the conversation summary key-value table rows
        let manifestRows: [String] = [
            ("Case ID", "[CASE-ID]"),
            ("Evidence Custodian", context.evidenceCustodian),
            ("Extraction Engine", exportEngineDescription()),
            ("Host Target Hardware", context.hostName),
            ("Thread Profile", thread.chatIdentifier.isEmpty ? thread.guid : thread.chatIdentifier),
            ("Thread GUID", thread.guid.isEmpty ? "[unavailable]" : thread.guid),
            ("Temporal Start", formatter.string(from: messages.first?.date ?? Date())),
            ("Temporal End", formatter.string(from: messages.last?.date ?? Date())),
            ("Total Record Count", String(messages.count))
        ].map { key, value in
            "<tr><th>\(escapeHTML(key))</th><td>\(escapeHTML(value))</td></tr>"
        }

        // Build the list items for mapped thread participants
        let participantRows: [String] = participantEntries(for: thread, messages: messages, context: context).map { handle, name in
            let resolved = name.isEmpty ? "Unresolved" : name
            return "<li><span class=\"participant-handle\">\(escapeHTML(handle))</span><span class=\"participant-name\">\(escapeHTML(resolved))</span></li>"
        }

        // Map individual message objects into raw, standard table rows that prevent WebKit vertical stretching.
        // Rather than using Grid or Flexbox (which crash or stretch vertically on pagination breaks inside WebKit),
        // each message row is constructed as an independent 2-cell HTML table to isolate page breaks.
        let messageRows: [String] = messages.map { message in
            let direction = message.isFromMe ? "Sent" : "Received"
            let bubbleClass = message.isFromMe ? "outgoing" : "incoming"
            let senderName = resolveDisplayName(for: message, thread: thread, context: context)
            let messageText = escapeHTML(message.text.isEmpty ? "[No message text]" : message.text)
            let timestamp = formatter.string(from: message.date)
            let guid = "message-\(thread.chatID)-\(message.messageID)"

            return """
            <table class="message-row">
              <tr>
                <td class="bubble-column">
                  <div class="sender-line">\(escapeHTML(senderName))</div>
                  <div class="bubble \(bubbleClass)">\(messageText)</div>
                </td>
                <td class="meta-card">
                  <div><strong>Timestamp</strong><br>\(escapeHTML(timestamp))</div>
                  <div><strong>Message GUID</strong><br>\(escapeHTML(guid))</div>
                  <div><strong>Direction</strong><br>\(escapeHTML(direction))</div>
                </td>
              </tr>
            </table>
            """
        }

        let threadTitle = escapeHTML(context.threadTitle)
        let sourceLabel = escapeHTML(context.sourceDisplayName)
        let legalNotice = escapeHTML("This export was generated locally from the selected message source. The PDF is accompanied by sidecar files for review, including CSV rows and a manifest JSON with file hashes where available.")

        // Output the final monolithic HTML template
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            /* Define print properties for standard A4 size. Page padding is handled by .pdf-page. */
            @page {
              size: A4;
              margin: 0;
            }
            /* Reset body properties and strip Flex/Grid wrappers to avoid infinite canvas expansion */
            html, body {
              display: block !important;
              width: 595px !important;
              height: auto !important;
              max-height: none !important;
              overflow: visible !important;
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
              color: #000000 !important;
              margin: 0;
              padding: 0;
              background: #ffffff !important;
              -webkit-print-color-adjust: exact;
              print-color-adjust: exact;
            }
            #pagination-source {
              display: block;
            }
            #pdf-pages {
              display: block;
              position: absolute;
              left: -10000px;
              top: 0;
              width: 595px;
              visibility: hidden;
            }
            body.paginated #pagination-source {
              display: none !important;
            }
            body.paginated #pdf-pages {
              display: block !important;
              position: static;
              left: auto;
              top: auto;
              visibility: visible;
            }
            .pdf-page {
              width: 595px;
              height: 842px;
              box-sizing: border-box;
              padding: 36px;
              margin: 0;
              background: #ffffff;
              overflow: hidden;
              page-break-after: always;
              break-after: page;
            }
            .pdf-page:last-child {
              page-break-after: auto;
              break-after: auto;
            }
            .page-content {
              width: 100%;
              height: 100%;
              overflow: hidden;
            }
            .page-overflow {
              font-size: 11px;
              line-height: 1.4;
              padding: 10px 12px;
              border: 1px solid #000000;
              background: #fff4d6;
              color: #000000;
            }
            .cover {
              display: block !important;
              height: auto !important;
              padding-top: 10px;
              color: #000000 !important;
            }
            .eyebrow {
              font-size: 11px;
              text-transform: uppercase;
              letter-spacing: 0.2em;
              color: #000000 !important;
              font-weight: bold;
              margin-bottom: 8px;
            }
            h1 {
              font-size: 26px;
              margin: 0 0 16px 0;
              color: #000000 !important;
            }
            .subtitle {
              font-size: 13px;
              color: #000000 !important;
              margin-bottom: 18px;
            }
            .manifest-table {
              width: 100%;
              border-collapse: collapse;
              margin: 12px 0 22px 0;
              font-size: 12px;
              color: #000000 !important;
            }
            .manifest-table th,
            .manifest-table td {
              border: 1px solid #000000;
              padding: 10px 12px;
              vertical-align: top;
              text-align: left;
              color: #000000 !important;
            }
            .manifest-table th {
              width: 32%;
              background: #f2f2f2 !important;
              font-weight: 700;
              color: #000000 !important;
            }
            .participants {
              margin: 16px 0 22px 0;
              padding: 14px 16px;
              background: #f8fafc;
              border: 1px solid #000000;
              border-radius: 6px;
              color: #000000 !important;
            }
            .participants strong {
              color: #000000 !important;
            }
            .participants ul {
              margin: 8px 0 0 0;
              padding-left: 18px;
              color: #000000 !important;
            }
            .participant-handle {
              font-weight: 600;
              color: #000000 !important;
            }
            .participant-name {
              display: inline-block;
              margin-left: 8px;
              color: #000000 !important;
            }
            .legal-block {
              margin-top: 28px;
              padding: 14px 16px;
              border-top: 2px solid #000000;
              font-size: 12px;
              color: #000000 !important;
            }
            .stream {
              display: block !important;
              height: auto !important;
              padding-top: 8px;
              color: #000000 !important;
            }
            .stream h2 {
              font-size: 19px;
              margin: 0 0 16px 0;
              color: #000000 !important;
            }
            /* Table-based Row Layout: Disables Flexbox and utilizes print-safe display blocks.
               This enforces page-break boundaries, pushing rows onto new pages seamlessly. */
            .message-row {
              width: 100% !important;
              border-collapse: collapse !important;
              margin-bottom: 16px !important;
              page-break-inside: avoid !important; /* Forces legacy WebKit to push row to next page */
              break-inside: avoid !important;      /* Enforces page-break avoidance in modern AppKit layout engines */
            }
            /* Table Cells: Forces structural block side-by-side columns to render independently. */
            .bubble-column {
              display: table-cell !important;
              vertical-align: top !important;
              width: 62% !important;
              padding-right: 12px;
              box-sizing: border-box;
              color: #000000 !important;
            }
            .sender-line {
              font-size: 12px;
              font-weight: 700;
              color: #000000 !important;
              margin: 0 0 6px 6px;
            }
            .bubble {
              border-radius: 8px;
              padding: 10px 12px;
              font-size: 12px;
              line-height: 1.4;
              white-space: pre-wrap;
              word-break: break-word;
              border: 1px solid #dcdcdc;
              color: #000000 !important;
            }
            .bubble.incoming {
              background: #f2f2f2 !important;
              color: #000000 !important;
            }
            .bubble.outgoing {
              background: #e6f0fa !important;
              color: #000000 !important;
            }
            .meta-card {
              display: table-cell !important;
              vertical-align: top !important;
              width: 38% !important;
              box-sizing: border-box;
              border: 1px solid #000000;
              background: #fdfdfd;
              border-radius: 6px;
              padding: 8px 10px;
              font-size: 11px;
              line-height: 1.4;
              color: #000000 !important;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            .meta-card div {
              color: #000000 !important;
            }
            .meta-card div + div { margin-top: 8px; }
            .meta-card strong { color: #000000 !important; }
          </style>
        </head>
        <body>
          <div id="pagination-source">
            <section class="cover">
              <div class="eyebrow">Local Message Export</div>
              <h1>Conversation Export Summary</h1>
              <div class="subtitle">Thread: \(threadTitle) • Source: \(sourceLabel)</div>
              <table class="manifest-table">
                <tbody>
                  \(manifestRows.joined(separator: ""))
                </tbody>
              </table>
              <div class="participants">
                <strong>Participants</strong>
                <ul>
                  \(participantRows.joined(separator: ""))
                </ul>
              </div>
              <div class="legal-block">
                <strong>Export Note:</strong><br>\(legalNotice)
              </div>
            </section>
            <section class="stream">
              <h2 data-stream-title>Itemized Message Stream</h2>
              <div id="message-source">
                \(messageRows.joined(separator: ""))
              </div>
            </section>
          </div>
          <div id="pdf-pages"></div>
          <script>
            (function() {
              function createPage() {
                var page = document.createElement('section');
                page.className = 'pdf-page';
                var content = document.createElement('div');
                content.className = 'page-content';
                page.appendChild(content);
                document.getElementById('pdf-pages').appendChild(page);
                return content;
              }

              function fits(content) {
                return content.scrollHeight <= content.clientHeight + 1;
              }

              function appendWholeBlock(content, block) {
                content.appendChild(block);
                if (fits(content)) {
                  return true;
                }
                content.removeChild(block);
                return false;
              }

              function paginateExport() {
                try {
                var pages = document.getElementById('pdf-pages');
                pages.innerHTML = '';

                var cover = document.querySelector('.cover').cloneNode(true);
                var coverPage = createPage();
                coverPage.appendChild(cover);
                if (!fits(coverPage)) {
                  coverPage.appendChild(document.createElement('div')).className = 'page-overflow';
                }

                var currentPage = createPage();
                var title = document.querySelector('[data-stream-title]').cloneNode(true);
                currentPage.appendChild(title);

                var rows = document.querySelectorAll('#message-source .message-row');
                rows.forEach(function(row) {
                  var clone = row.cloneNode(true);
                  if (!appendWholeBlock(currentPage, clone)) {
                    currentPage = createPage();
                    if (!appendWholeBlock(currentPage, clone)) {
                      clone.classList.add('page-overflow');
                      currentPage.appendChild(clone);
                    }
                  }
                });

                document.body.classList.add('paginated');
                window.__BBV_PAGINATED__ = true;
                } catch (error) {
                  window.__BBV_PAGINATION_ERROR__ = error && error.message ? error.message : String(error);
                }
              }

              function schedulePagination() {
                setTimeout(paginateExport, 0);
              }

              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', schedulePagination);
              } else {
                schedulePagination();
              }
            })();
          </script>
        </body>
        </html>
        """
    }

    /// Prepares an offscreen window context, instantiates a non-zero layout canvas inside a `WKWebView`,
    /// loads the generated HTML, and blocks execution asynchronously until the PDF compilation finishes.
    @MainActor
    private func renderHTMLAsync(_ html: String,
                                 to outputURL: URL) async throws {
        let pageRect = Self.a4PageRect

        // Create an offscreen window framework. This is critical because Cocoa's WebKit rendering engine
        // will not compute canvas layouts or process rendering calls if its host view has no window association.
        let window = NSWindow(
            contentRect: pageRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Initialize WebKit view with explicit non-zero A4 dimensions.
        let webView = WKWebView(frame: pageRect)
        window.contentView?.addSubview(webView)

        // Secure a strong reference to the web view inside the class singleton instance.
        // This ensures ARC does not clean it up mid-render while awaiting asynchronous delegate callbacks.
        self.activeWebView = webView

        // Clean up the class property reference when this method returns (success or failure)
        defer {
            self.activeWebView = nil
        }

        // Bridge Swift's modern async-await concurrency with Cocoa's delegate-based callback pattern.
        // We halt execution using withCheckedThrowingContinuation until the navigation delegate completes or fails.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = PDFNavigationDelegate(outputURL: outputURL) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Assign the strongly retained delegate and begin loading the generated HTML payload
            webView.navigationDelegate = delegate
            webView.loadHTMLString(html, baseURL: nil)

            // Dynamic layout timeout protection: triggers an error if loading exceeds 15 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                delegate.complete(with: .failure(ExportPDFError.renderFailed("Timed out while preparing the export preview.")))
            }
        }

        // Explicitly maintain scope reference lifetime for the window and view
        _ = window
        _ = webView
    }

    /// Utility helper to resolve the sender display name for a specific message,
    /// cross-referencing contact state maps.
    private func resolveDisplayName(for message: MessageItem,
                                    thread: ChatThread,
                                    context: ExportRenderContext) -> String {
        if message.isFromMe {
            return "You"
        }

        if !message.senderID.isEmpty, let name = context.resolvedNames[message.senderID], !name.isEmpty {
            return name
        }

        if !message.senderID.isEmpty {
            return message.senderID
        }

        if !thread.displayName.isEmpty {
            return thread.displayName
        }

        return thread.chatIdentifier.isEmpty ? "Unknown Participant" : thread.chatIdentifier
    }

    /// Resolves and aggregates unique participant identities mapped across thread logs.
    private func participantEntries(for thread: ChatThread,
                                    messages: [MessageItem],
                                    context: ExportRenderContext) -> [(handle: String, name: String)] {
        var handles: [String] = []

        if !thread.chatIdentifier.isEmpty {
            handles.append(thread.chatIdentifier)
        }

        if !thread.participantHandles.isEmpty {
            handles.append(contentsOf: thread.participantHandles.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        }

        for message in messages where !message.senderID.isEmpty {
            handles.append(message.senderID)
        }

        var seen = Set<String>()
        var entries: [(String, String)] = []
        for handle in handles where !handle.isEmpty && seen.insert(handle).inserted {
            let resolved = context.resolvedNames[handle] ?? ""
            entries.append((handle, resolved))
        }

        if entries.isEmpty {
            let fallback = context.threadTitle
            entries.append((thread.chatIdentifier.isEmpty ? "thread" : thread.chatIdentifier, fallback))
        }

        return entries
    }

    /// Generates a brief participant sequence to summarize the thread structure.
    private func participantSummary(for thread: ChatThread,
                                    messages: [MessageItem],
                                    context: ExportRenderContext) -> String {
        let entries = participantEntries(for: thread, messages: messages, context: context)
        let names = entries.map { entry in
            let resolved = entry.name.isEmpty ? entry.handle : "\(entry.name) (\(entry.handle))"
            return resolved
        }
        return names.prefix(4).joined(separator: "_")
    }

    /// Sanitizes files paths to eliminate illegal filesystem characters.
    private func sanitizeFileNameComponent(_ text: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>\n\r\t")
        let filtered = text.unicodeScalars.filter { !invalidCharacters.contains($0) }
        return String(filtered).replacingOccurrences(of: " ", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedExportFolderURL(from selectedURL: URL) -> URL {
        selectedURL.pathExtension.lowercased() == "pdf"
            ? selectedURL.deletingPathExtension()
            : selectedURL
    }

    private func createPackageDirectory(at requestedFolderURL: URL,
                                        fileManager: FileManager = .default) throws -> URL {
        let parentDirectory = requestedFolderURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let requestedName = requestedFolderURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = requestedName.isEmpty
            ? "conversation_export"
            : requestedName

        var candidate = parentDirectory.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentDirectory.appendingPathComponent("\(folderName) \(suffix)", isDirectory: true)
            suffix += 1
        }

        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    private func originalFilename(for attachment: AttachmentItem) -> String {
        let filename = URL(fileURLWithPath: attachment.filename).lastPathComponent
        if !filename.isEmpty {
            return filename
        }
        if !attachment.guid.isEmpty {
            return attachment.guid
        }
        return "attachment-\(attachment.attachmentID)"
    }

    private func copiedAttachmentFilename(for attachment: AttachmentItem, messageID: Int64) -> String {
        let sanitizedName = sanitizeFileNameComponent(originalFilename(for: attachment))
        let suffix = sanitizedName.isEmpty ? "attachment" : sanitizedName
        return "message-\(messageID)-attachment-\(attachment.attachmentID)-\(suffix)"
    }

    private func attachmentByteSize(for attachment: AttachmentItem, fileManager: FileManager) -> Int64 {
        if attachment.totalBytes > 0 {
            return attachment.totalBytes
        }

        guard let url = attachment.fileURL,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private func relativePath(from baseURL: URL, to fileURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(basePath.count + 1))
    }

    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func nonEmptyVersionComponent(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Safely escapes specialized HTML entity tags, avoiding raw tag parsing errors inside WebKit.
    private func escapeHTML(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&" + "amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&" + "lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&" + "gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&" + "quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&" + "#39;")
        return escaped
    }

}

// MARK: - Navigation Delegate
/// `PDFNavigationDelegate` acts as the coordinator between the WebKit frame lifecycle and PDF compilation.
/// It retains its own memory context strongly during active compilation, automatically cleaning up upon completion.
private final class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    private var completion: ((Result<Void, Error>) -> Void)?
    private var didFinish = false
    private let outputURL: URL
    private var strongSelf: PDFNavigationDelegate?

    init(outputURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        self.outputURL = outputURL
        self.completion = completion
        super.init()
        self.strongSelf = self
    }

    /// Resolves the completion block, releasing self-retained references to permit standard deallocation.
    func complete(with result: Result<Void, Error>) {
        guard !didFinish else { return }
        didFinish = true
        completion?(result)
        completion = nil
        strongSelf = nil // Break the self-retaining cycle to allow deallocation
    }

    /// Standard navigation completed callback. Checks document readiness status,
    /// then initiates the vector createPDF WebKit rendering operation.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForHTMLPagination(in: webView)
    }

    private func waitForHTMLPagination(in webView: WKWebView, attempt: Int = 0) {
        let script = """
        ({
          isReady: Boolean(window.__BBV_PAGINATED__ === true && document.body.classList.contains('paginated')),
          error: window.__BBV_PAGINATION_ERROR__ || null
        })
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self else { return }

            if let error {
                self.complete(with: .failure(error))
                return
            }

            if let state = result as? [String: Any],
               let message = state["error"] as? String,
               !message.isEmpty {
                self.complete(with: .failure(ExportPDFError.renderFailed("Failed to lay out A4 export pages: \(message)")))
                return
            }

            if let state = result as? [String: Any],
               (state["isReady"] as? Bool) == true {
                self.renderPDF(from: webView)
                return
            }

            guard attempt < 100 else {
                self.complete(with: .failure(ExportPDFError.renderFailed("Timed out while laying out A4 export pages.")))
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.waitForHTMLPagination(in: webView, attempt: attempt + 1)
            }
        }
    }

    private func renderPDF(from webView: WKWebView) {
        // Invoke the modern WebKit vector PDF compilation API. The HTML has already
        // moved whole message rows into fixed A4 page containers before this point.
        let configuration = WKPDFConfiguration()
        webView.createPDF(configuration: configuration) { [weak self] pdfResult in
            guard let self = self else { return }

            switch pdfResult {
            case .success(let data):
                do {
                    let paginatedData = try ExportPDFService.paginatedA4PDFData(from: data)
                    try paginatedData.write(to: self.outputURL)
                    self.complete(with: .success(()))
                } catch {
                    self.complete(with: .failure(error))
                }
            case .failure(let error):
                self.complete(with: .failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(with: .failure(error))
    }
}

/// Custom localized error descriptions for standard rendering failures.
enum ExportPDFError: LocalizedError {
    case renderFailed(String)
    case invalidPDFData

    var errorDescription: String? {
        switch self {
        case .renderFailed(let message):
            return message
        case .invalidPDFData:
            return "The PDF renderer returned data that could not be paginated."
        }
    }
}

extension ExportPDFService {
    static func paginatedA4PDFData(from data: Data) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData),
              let sourceDocument = CGPDFDocument(provider) else {
            throw ExportPDFError.invalidPDFData
        }

        let output = NSMutableData()
        var targetRect = a4PageRect
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &targetRect, nil) else {
            throw ExportPDFError.invalidPDFData
        }

        let sourcePageCount = max(sourceDocument.numberOfPages, 1)

        for pageIndex in 1...sourcePageCount {
            guard let sourcePage = sourceDocument.page(at: pageIndex) else { continue }

            let sourceBox = sourcePage.getBoxRect(.mediaBox)
            let scale = min(targetRect.width / sourceBox.width, 1.0)
            let sliceHeightInSource = targetRect.height / scale
            let sliceCount = max(Int(ceil(sourceBox.height / sliceHeightInSource)), 1)

            for sliceIndex in 0..<sliceCount {
                context.beginPDFPage(nil)
                context.saveGState()
                context.clip(to: targetRect)
                context.scaleBy(x: scale, y: scale)

                let yOffset = (targetRect.height / scale) - sourceBox.height + (CGFloat(sliceIndex) * sliceHeightInSource)
                context.translateBy(x: -sourceBox.minX, y: yOffset - sourceBox.minY)
                context.drawPDFPage(sourcePage)

                context.restoreGState()
                context.endPDFPage()
            }
        }

        context.closePDF()
        return output as Data
    }
}
