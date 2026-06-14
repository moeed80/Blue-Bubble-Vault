import AppKit
import Foundation
import WebKit
import CoreGraphics

final class ExportPDFService {
    static let shared = ExportPDFService()

    @MainActor
    func exportThread(to outputURL: URL,
                      thread: ChatThread,
                      messages: [MessageItem],
                      appState: AppState) async throws -> URL {
        let destinationURL = outputURL.pathExtension.lowercased() == "pdf"
            ? outputURL
            : outputURL.appendingPathExtension("pdf")

        let parentDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let orderedMessages = messages.sorted { $0.date < $1.date }
        let html = buildHTML(for: thread, messages: orderedMessages, appState: appState)
        try await renderHTMLAsync(html, thread: thread, messages: orderedMessages, appState: appState, to: destinationURL)
        return destinationURL
    }

    @MainActor
    func exportThreadAsync(to outputURL: URL,
                           thread: ChatThread,
                           messages: [MessageItem],
                           appState: AppState) async throws -> URL {
        let destinationURL = outputURL.pathExtension.lowercased() == "pdf"
            ? outputURL
            : outputURL.appendingPathExtension("pdf")

        let parentDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let orderedMessages = messages.sorted { $0.date < $1.date }
        let html = buildHTML(for: thread, messages: orderedMessages, appState: appState)
        try await renderHTMLAsync(html, thread: thread, messages: orderedMessages, appState: appState, to: destinationURL)
        return destinationURL
    }

    func defaultFileName(for thread: ChatThread, messages: [MessageItem], appState: AppState) -> String {
        let participants = participantSummary(for: thread, messages: messages, appState: appState)
        let threadLabel = participants.isEmpty ? appState.resolveThreadTitle(thread) : participants
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

    private func buildHTML(for thread: ChatThread,
                           messages: [MessageItem],
                           appState: AppState) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let manifestRows: [String] = [
            ("Case ID", "[CASE-ID]"),
            ("Evidence Custodian", "Moeed Ahmad"),
            ("Extraction Engine", "Blue Bubble Vault"),
            ("Host Target Hardware", hostName()),
            ("Thread Profile", thread.chatIdentifier.isEmpty ? thread.guid : thread.chatIdentifier),
            ("Thread GUID", thread.guid.isEmpty ? "[unavailable]" : thread.guid),
            ("Temporal Start", formatter.string(from: messages.first?.date ?? Date())),
            ("Temporal End", formatter.string(from: messages.last?.date ?? Date())),
            ("Total Record Count", String(messages.count))
        ].map { key, value in
            "<tr><th>\(escapeHTML(key))</th><td>\(escapeHTML(value))</td></tr>"
        }

        let participantRows: [String] = participantEntries(for: thread, messages: messages, appState: appState).map { handle, name in
            let resolved = name.isEmpty ? "Unresolved" : name
            return "<li><span class=\"participant-handle\">\(escapeHTML(handle))</span><span class=\"participant-name\">\(escapeHTML(resolved))</span></li>"
        }

        let messageRows: [String] = messages.enumerated().map { index, message in
            let direction = message.isFromMe ? "Sent" : "Received"
            let bubbleClass = message.isFromMe ? "outgoing" : "incoming"
            let senderName = resolveDisplayName(for: message, thread: thread, appState: appState)
            let messageText = escapeHTML(message.text.isEmpty ? "[No message text]" : message.text)
            let timestamp = formatter.string(from: message.date)
            let guid = "message-\(thread.chatID)-\(message.messageID)"

            return """
            <article class=\"message-row\">
              <div class=\"bubble-column\">
                <div class=\"sender-line\">\(escapeHTML(senderName))</div>
                <div class=\"bubble \(bubbleClass)\">\(messageText)</div>
              </div>
              <aside class=\"meta-card\">
                <div><strong>Timestamp</strong><br>\(escapeHTML(timestamp))</div>
                <div><strong>Message GUID</strong><br>\(escapeHTML(guid))</div>
                <div><strong>Direction</strong><br>\(escapeHTML(direction))</div>
              </aside>
            </article>
            """
        }

        let threadTitle = escapeHTML(appState.resolveThreadTitle(thread))
        let sourceLabel = escapeHTML(appState.selectedSource?.displayName ?? "Unknown")
        let legalNotice = escapeHTML("This export was generated directly from the local forensic archive layers and is intended for evidentiary review, chain-of-custody documentation, and legal discovery workflows.")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset=\"utf-8\">
          <style>
            @page { size: Letter; margin: 0.55in; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
              color: #1f2937;
              margin: 0;
              padding: 0;
              background: white;
            }
            .page { page-break-after: always; }
            .cover {
              padding: 8px 0 0 0;
            }
            .eyebrow {
              font-size: 11px;
              text-transform: uppercase;
              letter-spacing: 0.2em;
              color: #64748b;
              margin-bottom: 8px;
            }
            h1 {
              font-size: 26px;
              margin: 0 0 16px 0;
              color: #0f172a;
            }
            .subtitle {
              font-size: 13px;
              color: #475569;
              margin-bottom: 18px;
            }
            .manifest-table {
              width: 100%;
              border-collapse: collapse;
              margin: 12px 0 22px 0;
              font-size: 12px;
            }
            .manifest-table th,
            .manifest-table td {
              border: 1px solid #dbe2ea;
              padding: 10px 12px;
              vertical-align: top;
              text-align: left;
            }
            .manifest-table th {
              width: 32%;
              background: #f8fafc;
              font-weight: 700;
            }
            .participants {
              margin: 16px 0 22px 0;
              padding: 14px 16px;
              background: #f8fafc;
              border: 1px solid #e2e8f0;
              border-radius: 8px;
            }
            .participants ul {
              margin: 8px 0 0 0;
              padding-left: 18px;
            }
            .participant-handle {
              font-weight: 600;
              color: #0f172a;
            }
            .participant-name {
              display: inline-block;
              margin-left: 8px;
              color: #475569;
            }
            .legal-block {
              margin-top: 28px;
              padding: 14px 16px;
              border-top: 2px solid #cbd5e1;
              font-size: 12px;
              color: #334155;
            }
            .stream {
              page-break-before: always;
              padding-top: 8px;
            }
            .stream h2 {
              font-size: 19px;
              margin: 0 0 16px 0;
            }
            .message-row {
              display: grid;
              grid-template-columns: 62% 38%;
              gap: 14px;
              margin: 0 0 16px 0;
              page-break-inside: avoid;
              break-inside: avoid;
              align-items: start;
            }
            .sender-line {
              font-size: 12px;
              font-weight: 700;
              color: #334155;
              margin: 0 0 6px 6px;
            }
            .bubble {
              border-radius: 14px;
              padding: 11px 13px;
              font-size: 12px;
              line-height: 1.45;
              white-space: pre-wrap;
              word-break: break-word;
              box-shadow: 0 1px 2px rgba(15,23,42,0.04);
            }
            .bubble.incoming {
              background: #e8edf3;
              color: #0f172a;
            }
            .bubble.outgoing {
              background: #dbeafe;
              color: #0f172a;
            }
            .meta-card {
              border: 1px solid #dbe2ea;
              background: #f8fafc;
              border-radius: 10px;
              padding: 10px 12px;
              font-size: 11px;
              line-height: 1.5;
              color: #475569;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            .meta-card div + div { margin-top: 8px; }
            .meta-card strong { color: #0f172a; }
          </style>
        </head>
        <body>
          <section class=\"page cover\">
            <div class=\"eyebrow\">Forensic Evidence Export</div>
            <h1>Conversation Manifest</h1>
            <div class=\"subtitle\">Prepared for legal review • Thread: \(threadTitle) • Source: \(sourceLabel)</div>
            <table class=\"manifest-table\">
              <tbody>
                \(manifestRows.joined(separator: ""))
              </tbody>
            </table>
            <div class=\"participants\">
              <strong>Unified Mapped Participants</strong>
              <ul>
                \(participantRows.joined(separator: ""))
              </ul>
            </div>
            <div class=\"legal-block\">
              <strong>Compliance Notice:</strong><br>\(legalNotice)
            </div>
          </section>
          <section class=\"stream\">
            <h2>Itemized Message Stream</h2>
            \(messageRows.joined(separator: ""))
          </section>
        </body>
        </html>
        """
    }

    @MainActor
    private func renderHTMLAsync(_ html: String,
                                 thread: ChatThread,
                                 messages: [MessageItem],
                                 appState: AppState,
                                 to outputURL: URL) async throws {
        let pageSize = CGSize(width: 816, height: 1056)
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ExportPDFError.renderFailed("Unable to initialize the PDF renderer.")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var currentY: CGFloat = 980
        var currentPage = 1

        func newPageIfNeeded(_ requiredHeight: CGFloat) {
            if currentY - requiredHeight < 80 {
                context.endPDFPage()
                context.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(origin: .zero, size: pageSize)] as CFDictionary)
                currentY = 980
                currentPage += 1
            }
        }

        func drawText(_ text: String, at point: CGPoint, fontSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, alignment: NSTextAlignment = .left, maxWidth: CGFloat? = nil) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = alignment
            paragraphStyle.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let rect = CGRect(x: point.x, y: point.y, width: maxWidth ?? 720, height: 1000)
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            attributed.draw(with: rect, options: options, context: nil)
        }

        func drawWrappedText(_ text: String, in rect: CGRect, fontSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }

        func withPDFGraphicsContext(_ body: () -> Void) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            body()
        }

        func drawBox(rect: CGRect, fillColor: NSColor = .white, strokeColor: NSColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            fillColor.setFill()
            path.fill()
            strokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        func drawMessage(_ message: MessageItem, atTopOfPage: inout CGFloat, pageNumber: Int) {
            let senderName = resolveDisplayName(for: message, thread: thread, appState: appState)
            let bubbleColor: NSColor = message.isFromMe ? NSColor(red: 0.18, green: 0.46, blue: 0.95, alpha: 0.16) : NSColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
            let textColor: NSColor = .labelColor
            let timestamp = formatter.string(from: message.date)
            let body = message.text.isEmpty ? "[No message text]" : message.text
            let bodyHeight = estimateHeight(for: body, width: 560, fontSize: 13)
            let rowHeight = max(80, bodyHeight + 70)

            newPageIfNeeded(rowHeight + 20)

            let boxRect = CGRect(x: 48, y: atTopOfPage - rowHeight, width: 720, height: rowHeight)
            drawBox(rect: boxRect, fillColor: bubbleColor, strokeColor: NSColor(calibratedWhite: 0.84, alpha: 1.0))

            drawText(senderName, at: CGPoint(x: 62, y: atTopOfPage - 24), fontSize: 12, weight: .semibold, color: .secondaryLabelColor)
            drawWrappedText(body, in: CGRect(x: 62, y: atTopOfPage - rowHeight + 30, width: 560, height: rowHeight - 60), fontSize: 13, weight: .regular, color: textColor)
            drawText("\(timestamp) • \(message.isFromMe ? "Sent" : "Received")", at: CGPoint(x: 62, y: atTopOfPage - rowHeight + 10), fontSize: 10, weight: .regular, color: .secondaryLabelColor)

            atTopOfPage -= rowHeight + 16
        }

        context.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(origin: .zero, size: pageSize)] as CFDictionary)

        withPDFGraphicsContext {
            drawText("Conversation Manifest", at: CGPoint(x: 48, y: 930), fontSize: 28, weight: .bold)
            drawText("Prepared for legal review", at: CGPoint(x: 48, y: 900), fontSize: 13, color: .secondaryLabelColor)
            drawText("Thread: \(appState.resolveThreadTitle(thread))", at: CGPoint(x: 48, y: 875), fontSize: 14, weight: .semibold)
            drawText("Source: \(appState.selectedSource?.displayName ?? "Unknown")", at: CGPoint(x: 48, y: 850), fontSize: 12, color: .secondaryLabelColor)

            let manifestItems = [
                ("Case ID", "[CASE-ID]"),
                ("Evidence Custodian", "Moeed Ahmad"),
                ("Extraction Engine", "Blue Bubble Vault"),
                ("Host Target Hardware", hostName()),
                ("Thread Profile", thread.chatIdentifier.isEmpty ? thread.guid : thread.chatIdentifier),
                ("Thread GUID", thread.guid.isEmpty ? "[unavailable]" : thread.guid),
                ("Temporal Start", formatter.string(from: messages.first?.date ?? Date())),
                ("Temporal End", formatter.string(from: messages.last?.date ?? Date())),
                ("Total Record Count", String(messages.count))
            ]

            var manifestY: CGFloat = 780
            for (label, value) in manifestItems {
                drawText(label, at: CGPoint(x: 48, y: manifestY), fontSize: 11, weight: .semibold, color: .secondaryLabelColor)
                drawText(value, at: CGPoint(x: 180, y: manifestY), fontSize: 12, weight: .regular, color: .labelColor, maxWidth: 560)
                manifestY -= 20
            }

            drawText("Participants", at: CGPoint(x: 48, y: 620), fontSize: 16, weight: .semibold)
            let participantEntries = participantEntries(for: thread, messages: messages, appState: appState)
            var participantY: CGFloat = 590
            for (handle, name) in participantEntries {
                let resolved = name.isEmpty ? "Unresolved" : name
                drawText("• \(resolved) (\(handle))", at: CGPoint(x: 62, y: participantY), fontSize: 12, color: .labelColor, maxWidth: 660)
                participantY -= 18
            }
        }

        context.endPDFPage()
        context.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(origin: .zero, size: pageSize)] as CFDictionary)
        currentY = 980

        withPDFGraphicsContext {
            drawText("Itemized Message Stream", at: CGPoint(x: 48, y: 980), fontSize: 22, weight: .bold)
            drawText("Chronological view of the selected conversation thread", at: CGPoint(x: 48, y: 950), fontSize: 12, color: .secondaryLabelColor)

            var currentTop: CGFloat = 930
            for message in messages {
                drawMessage(message, atTopOfPage: &currentTop, pageNumber: 2)
            }
        }

        context.endPDFPage()
        context.closePDF()

        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw ExportPDFError.renderFailed("Unable to write the exported PDF file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func waitForHTMLLoad(in webView: WKWebView, html: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = WebViewLoadDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            webView.loadHTMLString(html, baseURL: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                delegate.resumeIfPending(with: ExportPDFError.renderFailed("Timed out while preparing the export preview."))
            }
        }
    }

    private func resolveDisplayName(for message: MessageItem,
                                    thread: ChatThread,
                                    appState: AppState) -> String {
        if message.isFromMe {
            return "You"
        }

        if !message.senderID.isEmpty, let name = appState.resolvedNames[message.senderID], !name.isEmpty {
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

    private func participantEntries(for thread: ChatThread,
                                    messages: [MessageItem],
                                    appState: AppState) -> [(handle: String, name: String)] {
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
            let resolved = appState.resolvedNames[handle] ?? ""
            entries.append((handle, resolved))
        }

        if entries.isEmpty {
            let fallback = appState.resolveThreadTitle(thread)
            entries.append((thread.chatIdentifier.isEmpty ? "thread" : thread.chatIdentifier, fallback))
        }

        return entries
    }

    private func participantSummary(for thread: ChatThread,
                                    messages: [MessageItem],
                                    appState: AppState) -> String {
        let entries = participantEntries(for: thread, messages: messages, appState: appState)
        let names = entries.map { entry in
            let resolved = entry.name.isEmpty ? entry.handle : "\(entry.name) (\(entry.handle))"
            return resolved
        }
        return names.prefix(4).joined(separator: "_")
    }

    private func sanitizeFileNameComponent(_ text: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>\n\r\t")
        let filtered = text.unicodeScalars.filter { !invalidCharacters.contains($0) }
        return String(filtered).replacingOccurrences(of: " ", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapeHTML(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }

    private func hostName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return host.isEmpty ? "Local macOS Host" : host
    }

    private func estimateHeight(for text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let rect = attributed.boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return max(40, rect.height + 12)
    }
}

private final class WebViewLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Error>?
    private var finished = false

    init(continuation: CheckedContinuation<Bool, Error>) {
        self.continuation = continuation
    }

    func resumeIfPending(with error: Error? = nil) {
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: true)
        }
        self.continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        finished = true
        resumeIfPending()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !finished else { return }
        finished = true
        resumeIfPending(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !finished else { return }
        finished = true
        resumeIfPending(with: error)
    }
}

enum ExportPDFError: LocalizedError {
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let message):
            return message
        }
    }
}
