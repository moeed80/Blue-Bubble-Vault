import AppKit
import Foundation
import WebKit
import CoreGraphics

final class ExportPDFService {
    static let shared = ExportPDFService()

    @MainActor private var activeWebView: WKWebView?

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
        
        // 1. Synchronous HTML Diagnostic Dump - KEEP COMPLETELY INTACT
        let diagnosticURL = parentDirectory.appendingPathComponent("Forensic_Export_Verification.html")
        try html.write(to: diagnosticURL, atomically: true, encoding: .utf8)

        // 2. Asynchronous PDF Rendering
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

        // 1. Synchronous HTML Diagnostic Dump - KEEP COMPLETELY INTACT
        let diagnosticURL = parentDirectory.appendingPathComponent("Forensic_Export_Verification.html")
        try html.write(to: diagnosticURL, atomically: true, encoding: .utf8)

        // 2. Asynchronous PDF Rendering
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

        let messageRows: [String] = messages.map { message in
            let direction = message.isFromMe ? "Sent" : "Received"
            let bubbleClass = message.isFromMe ? "outgoing" : "incoming"
            let senderName = resolveDisplayName(for: message, thread: thread, appState: appState)
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

        let threadTitle = escapeHTML(appState.resolveThreadTitle(thread))
        let sourceLabel = escapeHTML(appState.selectedSource?.displayName ?? "Unknown")
        let legalNotice = escapeHTML("This export was generated directly from the local forensic archive layers and is intended for evidentiary review, chain-of-custody documentation, and legal discovery workflows.")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            @page {
              size: Letter;
              margin: 0.5in;
            }
            html, body {
              display: block !important;
              width: 100% !important;
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
            .cover {
              display: block !important;
              height: auto !important;
              page-break-after: always !important;
              break-after: page !important;
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
            .message-row {
              width: 100% !important;
              border-collapse: collapse !important;
              margin-bottom: 16px !important;
              page-break-inside: avoid !important; /* Forces legacy WebKit to push row to next page */
              break-inside: avoid !important;      /* Enforces page-break avoidance in modern AppKit layout engines */
            }
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
          <section class="cover">
            <div class="eyebrow">Forensic Evidence Export</div>
            <h1>Conversation Manifest</h1>
            <div class="subtitle">Prepared for legal review • Thread: \(threadTitle) • Source: \(sourceLabel)</div>
            <table class="manifest-table">
              <tbody>
                \(manifestRows.joined(separator: ""))
              </tbody>
            </table>
            <div class="participants">
              <strong>Unified Mapped Participants</strong>
              <ul>
                \(participantRows.joined(separator: ""))
              </ul>
            </div>
            <div class="legal-block">
              <strong>Compliance Notice:</strong><br>\(legalNotice)
            </div>
          </section>
          <section class="stream">
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
        // Create a borderless offscreen window with explicit frame size to host the web view hierarchy
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 816, height: 1056),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Give WKWebView an explicit physical frame size so it doesn't default to zero dimensions
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056))
        window.contentView?.addSubview(webView)

        // Ensure the service class orchestrating the export holds a strong property reference to the WKWebView instance
        self.activeWebView = webView

        defer {
            self.activeWebView = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = PDFNavigationDelegate(outputURL: outputURL) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            webView.navigationDelegate = delegate
            webView.loadHTMLString(html, baseURL: nil)

            // Dynamic layout timeout protection
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                delegate.complete(with: .failure(ExportPDFError.renderFailed("Timed out while preparing the export preview.")))
            }
        }

        // Keep local references strongly referenced during print execution scope to prevent early garbage collection
        _ = window
        _ = webView
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
        var escaped = text.replacingOccurrences(of: "&", with: "&" + "amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&" + "lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&" + "gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&" + "quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&" + "#39;")
        return escaped
    }

    private func hostName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return host.isEmpty ? "Local macOS Host" : host
    }
}

// MARK: - Navigation Delegate
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

    func complete(with result: Result<Void, Error>) {
        guard !didFinish else { return }
        didFinish = true
        completion?(result)
        completion = nil
        strongSelf = nil // Break the retain cycle
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.readyState") { [weak self] (result, error) in
            guard let self = self else { return }
            
            // Implement Modern WebKit PDF Compilation API
            let configuration = WKPDFConfiguration()
            webView.createPDF(configuration: configuration) { pdfResult in
                switch pdfResult {
                case .success(let data):
                    do {
                        try data.write(to: self.outputURL)
                        self.complete(with: .success(()))
                    } catch {
                        self.complete(with: .failure(error))
                    }
                case .failure(let error):
                    self.complete(with: .failure(error))
                }
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

enum ExportPDFError: LocalizedError {
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let message):
            return message
        }
    }
}
