import AppKit
import Foundation
import WebKit
import CoreGraphics

/// `ExportPDFService` is a singleton service class responsible for exporting a chat thread's message history
/// into two high-fidelity forensic formats: a diagnostic HTML file and a vector-perfect PDF.
///
/// This service utilizes a dual-output architecture designed for professional eDiscovery, legal discovery,
/// and forensic audit scenarios. It combines synchronous disk logging of raw layout markup with asynchronous,
/// offscreen WebKit rendering to guarantee that all messages are preserved, readable, and properly paginated.
final class ExportPDFService {
    /// Shared singleton instance of the export service.
    static let shared = ExportPDFService()

    /// Strong reference to the active `WKWebView` instance during an on-going PDF generation process.
    /// This prevents ARC (Automatic Reference Counting) from garbage-collecting the web view mid-render
    /// while the asynchronous layout engine compiles the document's geometry.
    @MainActor private var activeWebView: WKWebView?

    /// Exports a chat thread's message history to a PDF file at a user-specified destination URL.
    ///
    /// This is the primary entry point for exporting. It coordinates sorting message payloads,
    /// creating the destination directories, writing out the diagnostic HTML gate, and initiating
    /// the offscreen PDF compilation.
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
        // Enforce the standard ".pdf" file extension for the output target URL
        let destinationURL = outputURL.pathExtension.lowercased() == "pdf"
            ? outputURL
            : outputURL.appendingPathExtension("pdf")

        // Ensure that the target parent directory exists; create it recursively if missing
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        // Sort messages chronologically (ascending order) to represent an accurate legal timeline
        let orderedMessages = messages.sorted { $0.date < $1.date }
        
        // Assemble the complete document as a raw HTML string from data structures
        let html = buildHTML(for: thread, messages: orderedMessages, appState: appState)
        
        // 1. SYNCHRONOUS DIAGNOSTIC HTML DUMP
        // To prevent un-trackable rendering losses and simplify layout troubleshooting, we write
        // the un-rendered HTML directly to disk as 'Forensic_Export_Verification.html'.
        // If a layout engine bugs out, this static gate serves as our verifiable truth of extraction content.
        let diagnosticURL = parentDirectory.appendingPathComponent("Forensic_Export_Verification.html")
        try html.write(to: diagnosticURL, atomically: true, encoding: .utf8)

        // 2. ASYNCHRONOUS WEBVIEW RENDERING TO VECTOR PDF
        // Pass the static HTML into our offscreen rendering pipeline which compiles it into print-optimized PDF vectors.
        try await renderHTMLAsync(html, thread: thread, messages: orderedMessages, appState: appState, to: destinationURL)
        return destinationURL
    }

    /// Asynchronous alias of `exportThread`. Coordinates directory preparation, raw HTML serialization,
    /// diagnostic dump execution, and offscreen WebKit PDF vector compilation.
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

        // 1. SYNCHRONOUS DIAGNOSTIC HTML DUMP
        let diagnosticURL = parentDirectory.appendingPathComponent("Forensic_Export_Verification.html")
        try html.write(to: diagnosticURL, atomically: true, encoding: .utf8)

        // 2. ASYNCHRONOUS WEBVIEW RENDERING TO VECTOR PDF
        try await renderHTMLAsync(html, thread: thread, messages: orderedMessages, appState: appState, to: destinationURL)
        return destinationURL
    }

    /// Automatically generates a legally-structured default filename for exports,
    /// encoding key forensic identifiers: `Participant_StartYearMonthDay_to_EndYearMonthDay.pdf`.
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

    /// Assembles raw thread structures and message objects into a monolithic HTML string.
    /// This includes writing the layout style block, the evidence manifest cover,
    /// a participant list, and the itemized conversation stream.
    private func buildHTML(for thread: ChatThread,
                           messages: [MessageItem],
                           appState: AppState) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Build the Conversation Manifest key-value table rows
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

        // Build the list items for mapped thread participants
        let participantRows: [String] = participantEntries(for: thread, messages: messages, appState: appState).map { handle, name in
            let resolved = name.isEmpty ? "Unresolved" : name
            return "<li><span class=\"participant-handle\">\(escapeHTML(handle))</span><span class=\"participant-name\">\(escapeHTML(resolved))</span></li>"
        }

        // Map individual message objects into raw, standard table rows that prevent WebKit vertical stretching.
        // Rather than using Grid or Flexbox (which crash or stretch vertically on pagination breaks inside WebKit),
        // each message row is constructed as an independent 2-cell HTML table to isolate page breaks.
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

        // Output the final monolithic HTML template
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            /* Define print properties for standard Letter size with standard half-inch margins */
            @page {
              size: Letter;
              margin: 0.5in;
            }
            /* Reset body properties and strip Flex/Grid wrappers to avoid infinite canvas expansion */
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
            /* Ensure the cover manifest cover doesn't flex-stretch and breaks cleanly to Page 2 */
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

    /// Prepares an offscreen window context, instantiates a non-zero layout canvas inside a `WKWebView`,
    /// loads the generated HTML, and blocks execution asynchronously until the PDF compilation finishes.
    @MainActor
    private func renderHTMLAsync(_ html: String,
                                 thread: ChatThread,
                                 messages: [MessageItem],
                                 appState: AppState,
                                 to outputURL: URL) async throws {
        // Create an offscreen window framework. This is critical because Cocoa's WebKit rendering engine
        // will not compute canvas layouts or process rendering calls if its host view has no window association.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 816, height: 1056),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Initialize WebKit view with explicit non-zero Letter dimensions (816x1056)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056))
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

    /// Resolves and aggregates unique participant identities mapped across thread logs.
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

    /// Generates a brief participant sequence to summarize the thread structure.
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

    /// Sanitizes files paths to eliminate illegal filesystem characters.
    private func sanitizeFileNameComponent(_ text: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>\n\r\t")
        let filtered = text.unicodeScalars.filter { !invalidCharacters.contains($0) }
        return String(filtered).replacingOccurrences(of: " ", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Resolves the hostname profile of the target hardware logging the export.
    private func hostName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return host.isEmpty ? "Local macOS Host" : host
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
        webView.evaluateJavaScript("document.readyState") { [weak self] (result, error) in
            guard let self = self else { return }
            
            // Invoke the modern WebKit vector PDF compilation API
            let configuration = WKPDFConfiguration()
            webView.createPDF(configuration: configuration) { pdfResult in
                switch pdfResult {
                case .success(let data):
                    do {
                        // Persist the rendered vector PDF binary directly to disk
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

/// Custom localized error descriptions for standard rendering failures.
enum ExportPDFError: LocalizedError {
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let message):
            return message
        }
    }
}
