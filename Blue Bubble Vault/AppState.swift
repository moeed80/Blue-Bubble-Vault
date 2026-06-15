//
//  AppState.swift
//  Blue Bubble Vault
//
//  Created by Antigravity on 6/5/26.
//

import Foundation
import SwiftUI
import Combine

public enum DateFilterMode: String, CaseIterable, Identifiable {
    case all = "All Messages"
    case range = "Select Date Range"
    
    public var id: String { self.rawValue }
}

public final class AppState: ObservableObject {
    // Permission State
    @Published var hasFDA: Bool = false
    @Published var hasContactsPermission: Bool = false
    
    // Connection Sources
    @Published var databaseSources: [DatabaseSource] = []
    @Published var selectedSource: DatabaseSource? {
        didSet {
            handleSourceChange()
        }
    }
    
    // Chat Selection
    @Published var chatThreads: [ChatThread] = []
    @Published var searchText: String = ""
    @Published var selectedThread: ChatThread? {
        didSet {
            loadMessages()
        }
    }
    
    // Filter Parameters
    @Published var dateFilterMode: DateFilterMode = .all {
        didSet {
            loadMessages()
        }
    }
    @Published var startDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() {
        didSet {
            loadMessages()
        }
    }
    @Published var endDate: Date = Date() {
        didSet {
            loadMessages()
        }
    }
    @Published var keywordFilter: String = "" {
        didSet {
            loadMessages()
        }
    }
    @Published var includeMedia: Bool = true {
        didSet {
            loadMessages()
        }
    }
    
    // Loaded Data
    @Published var messages: [MessageItem] = []
    @Published var isQuerying: Bool = false
    
    // Contact Resolution Cache
    @Published var resolvedNames: [String: String] = [:]
    @Published var isContactsSynced: Bool = false
    
    // Contact Sync Toggle
    @Published var isContactSyncEnabled: Bool = false

    private var cancellables = Set<AnyCancellable>()
    
    init() {
        checkPermissionsAndScanSources()
        // Removed automatic contact sync to defer until explicit user action
        setupSimulatedData()
        checkAvailableSpace()
        
        // Default to iCloud if available, else simulated
        if let firstSource = databaseSources.first {
            selectedSource = firstSource
        }
        
        // Add onChange observer for contact sync toggle
        $isContactSyncEnabled.sink { [weak self] isEnabled in
            guard let self = self else { return }
            if isEnabled {
                // When user enables the toggle, request contacts permission
                self.requestContactsPermission()
            } else {
                // When user disables the toggle, reset the sync state
                self.isContactsSynced = false
            }
        }.store(in: &cancellables)
    }
    
    // Disk & Space Metrics
    @Published var estimatedExportSize: Int64 = 0
    @Published var availableSpace: Int64 = 0
    @Published var isSpaceSafe: Bool = true
    
    // Services
    public let databaseService = DatabaseService()
    private var simulatedThreads: [ChatThread] = []
    private var simulatedMessages: [Int64: [MessageItem]] = [:]
        
    private var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Checks the current FDA permission status, scans for active databases, and updates source lists.
    public func checkPermissionsAndScanSources() {
        if isRunningUnderXCTest {
            self.hasFDA = false
            self.databaseSources = [DatabaseSource(type: .icloud, path: "simulated_demo")]
            return
        }

        let fda = FDAPermissionManager.shared.checkFullDiskAccess()
        self.hasFDA = fda
        
        var sources: [DatabaseSource] = []
        
        // Add iCloud Live
        sources.append(DatabaseConnectionManager.shared.getICloudSource())
        
        // Add USB Backups if directory is accessible
        let backups = DatabaseConnectionManager.shared.scanUSBBackups()
        sources.append(contentsOf: backups)
        
        // Add Simulated Source so user has a fallback demo
        sources.append(DatabaseSource(type: .icloud, path: "simulated_demo"))
        
        self.databaseSources = sources
    }
    
    /// Requests System Settings redirection for FDA
    public func requestFDAPermission() {
        FDAPermissionManager.shared.openSystemSettingsForFDA()
    }
    
    /// Checks the native Contacts database permission status
    public func checkContactsPermission() {
        self.hasContactsPermission = ContactsManager.shared.checkAuthorizationStatus()
    }
    
    /// Prompts user to grant Contacts framework permission
    public func requestContactsPermission() {
        ContactsManager.shared.requestAccess { [weak self] granted in
            DispatchQueue.main.async {
                self?.hasContactsPermission = granted
                if granted {
                    self?.resolveNamesForThreads()
                }
            }
        }
    }
    
    /// Manually triggers contact name resolution after user action.
    public func requestContactSync() {
        guard hasContactsPermission else { return }
        resolveNamesForThreads()
        isContactsSynced = true
    }
    
    /// Refreshes disk size checks
    public func checkAvailableSpace() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        do {
            let values = try homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                self.availableSpace = capacity
            } else {
                self.availableSpace = 100 * 1024 * 1024 * 1024 // 100 GB fallback
            }
        } catch {
            print("Failed to get disk capacity: \(error.localizedDescription)")
            self.availableSpace = 100 * 1024 * 1024 * 1024 // 100 GB fallback
        }
    }
    
    /// Computed property for list filtering
    public var filteredThreads: [ChatThread] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chatThreads
        }
        return chatThreads.filter { thread in
            // Safely handle case where contacts haven't been synced yet
            let resolvedName = resolvedNames[thread.chatIdentifier] ?? thread.displayName
            return thread.chatIdentifier.localizedCaseInsensitiveContains(searchText) ||
                   thread.displayName.localizedCaseInsensitiveContains(searchText) ||
                   resolvedName.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    /// Resolves handles (emails, phone numbers) to contact names incrementally in the background.
    /// If a name is not yet resolved, the UI shows the raw number/ID as a fallback placeholder.
    public func resolveNamesForThreads() {
        // Build mock resolutions first (allows demo mode to look polished immediately)
        var tempNames: [String: String] = [:]
        if selectedSource?.path == "simulated_demo" {
            tempNames["+1 (555) 019-2834"] = "Alice Smith"
            tempNames["bob.jones@icloud.com"] = "Bob Jones"
            tempNames["+1 (800) 424-9090"] = "Apple Support"
            
            // Apply mock names immediately
            for (key, val) in tempNames {
                if self.resolvedNames[key] == nil {
                    self.resolvedNames[key] = val
                }
            }
        }
        
        guard hasContactsPermission else {
            return
        }
        
        let handles = chatThreads.map { $0.chatIdentifier }
        var allHandles = Set(handles)
        
        // Include senderIDs in active messages to resolve group chat names
        for msg in messages {
            if !msg.isFromMe && !msg.senderID.isEmpty {
                allHandles.insert(msg.senderID)
            }
        }
        
        // Optimize: Only resolve handles we haven't already cached
        let unresolvedHandles = allHandles.filter { self.resolvedNames[$0] == nil }
        guard !unresolvedHandles.isEmpty else { return }
        
        // Execute lookup asynchronously off the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            for handle in unresolvedHandles {
                if let name = ContactsManager.shared.resolveName(for: handle) {
                    // Publish single updates back to main thread incrementally
                    DispatchQueue.main.async {
                        self.resolvedNames[handle] = name
                    }
                }
            }
        }
    }
    
public func resolveThreadTitle(_ thread: ChatThread) -> String {
    // Prefer any resolved contact name for the thread identifier first.
    if let resolvedName = resolvedNames[thread.chatIdentifier], !resolvedName.isEmpty {
        return resolvedName
    }

    // If display name is set, use it.
    if !thread.displayName.isEmpty {
        return thread.displayName
    }

    // If chat identifier starts with "chat" (multi-user thread), resolve participant handles.
    if thread.chatIdentifier.starts(with: "chat") && !thread.participantHandles.isEmpty {
        let handles = thread.participantHandles.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        var resolvedNamesList: [String] = []

        for handle in handles {
            if let resolvedName = resolvedNames[handle], !resolvedName.isEmpty {
                resolvedNamesList.append(resolvedName)
            } else {
                resolvedNamesList.append(handle)
            }
        }

        return resolvedNamesList.joined(separator: ", ")
    }

    // Default fallback to chat identifier.
    return thread.chatIdentifier
}

func exportRenderContext(for thread: ChatThread) -> ExportRenderContext {
    ExportRenderContext(
        threadTitle: resolveThreadTitle(thread),
        sourceDisplayName: selectedSource?.displayName ?? "Unknown",
        resolvedNames: resolvedNames
    )
}
    
    // MARK: - Private Implementations
    
    private func handleSourceChange() {
        guard let source = selectedSource else {
            self.chatThreads = []
            self.selectedThread = nil
            return
        }
        
        self.isQuerying = true
        let sourcePath = source.path
        
        // Open DB and read threads list asynchronously in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var fetchedThreads: [ChatThread] = []
            
            if sourcePath == "simulated_demo" {
                fetchedThreads = self.simulatedThreads
            } else {
                let fda = FDAPermissionManager.shared.checkFullDiskAccess()
                DispatchQueue.main.async {
                    self.hasFDA = fda
                }
                
                if fda && self.databaseService.open(path: sourcePath) {
                    fetchedThreads = self.databaseService.fetchChatThreads()
                }
            }
            
            // Post updates back to UI main thread safely
            DispatchQueue.main.async {
                guard self.selectedSource?.path == sourcePath else { return }
                
                self.chatThreads = fetchedThreads
                self.selectedThread = fetchedThreads.first
                self.isQuerying = false
                
                self.resolveNamesForThreads()
            }
        }
    }
    
    private func loadMessages() {
        guard let source = selectedSource, let thread = selectedThread else {
            self.messages = []
            self.estimatedExportSize = 0
            self.isSpaceSafe = true
            return
        }
        
        self.isQuerying = true
        
        let start = dateFilterMode == .range ? startDate : nil
        let end = dateFilterMode == .range ? endDate : nil
        let key = keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : keywordFilter
        let includeMediaToggle = includeMedia
        let threadID = thread.chatID
        let sourcePath = source.path
        
        // Execute message queries and calculations on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var fetchedMessages: [MessageItem] = []
            var estimatedSize: Int64 = 0
            
            if sourcePath == "simulated_demo" {
                let allSimulated = self.simulatedMessages[threadID] ?? []
                
                fetchedMessages = allSimulated.filter { msg in
                    if let start = start, msg.date < start { return false }
                    if let end = end, msg.date > end { return false }
                    if let key = key, !msg.text.localizedCaseInsensitiveContains(key) { return false }
                    return true
                }
                
                let textBytes = Int64(fetchedMessages.count) * 200
                var mediaBytes: Int64 = 0
                if includeMediaToggle {
                    for msg in fetchedMessages {
                        mediaBytes += msg.attachments.reduce(0) { $0 + $1.totalBytes }
                    }
                }
                estimatedSize = textBytes + mediaBytes
            } else {
                if self.databaseService.isOpen {
                    fetchedMessages = self.databaseService.fetchMessages(
                        chatID: threadID,
                        startDate: start,
                        endDate: end,
                        keyword: key,
                        includeMedia: includeMediaToggle
                    )
                    
                    let textBytes = Int64(fetchedMessages.count) * 200
                    var mediaBytes: Int64 = 0
                    if includeMediaToggle {
                        mediaBytes = self.databaseService.fetchAttachmentTotalBytes(
                            chatID: threadID,
                            startDate: start,
                            endDate: end
                        )
                    }
                    estimatedSize = textBytes + mediaBytes
                }
            }
            
            // Dispatch final updates to the Main actor
            DispatchQueue.main.async {
                // Confirm selection did not change during query
                guard self.selectedThread?.chatID == threadID,
                      self.selectedSource?.path == sourcePath else {
                    return
                }
                
                self.messages = fetchedMessages
                self.estimatedExportSize = estimatedSize
                
                let safetyBuffer: Int64 = 500 * 1024 * 1024 // 500 MB
                self.isSpaceSafe = self.availableSpace > (estimatedSize + safetyBuffer)
                self.isQuerying = false
                
                self.resolveNamesForThreads()
            }
        }
    }
    
    // MARK: - Simulated Data Setup
    
    private func setupSimulatedData() {
        simulatedThreads = [
            ChatThread(chatID: 1, guid: "sim-chat-1", chatIdentifier: "+1 (555) 019-2834", displayName: "Alice Smith", messageCount: 18, participantHandles: "+1 (555) 019-2834"),
            ChatThread(chatID: 2, guid: "sim-chat-2", chatIdentifier: "bob.jones@icloud.com", displayName: "Bob Jones", messageCount: 17, participantHandles: "bob.jones@icloud.com"),
            ChatThread(chatID: 3, guid: "sim-chat-3", chatIdentifier: "chat8394850123", displayName: "Family Group", messageCount: 22, participantHandles: "Alice Smith, Bob Jones, Mom, Sister"),
            ChatThread(chatID: 4, guid: "sim-chat-4", chatIdentifier: "+1 (800) 424-9090", displayName: "Apple Support", messageCount: 16, participantHandles: "+1 (800) 424-9090")
        ]
        
        let now = Date()
        let oneDay: TimeInterval = 24 * 60 * 60
        
        simulatedMessages[1] = makeSimulatedThread(
            baseID: 100,
            senderID: "+1 (555) 019-2834",
            startDate: now.addingTimeInterval(-oneDay * 5),
            minutesBetweenMessages: 7,
            lines: [
                (false, "Hey! Are we still on for lunch today?", nil),
                (true, "Yes, definitely. Same Italian place as usual?", nil),
                (false, "Yep. They changed the lunch menu a little, but the patio is still open.", nil),
                (true, "Perfect. I have a hard stop at 1:30, so noon would be ideal.", nil),
                (false, "Noon works. I saved us a table outside.", nil),
                (false, "I grabbed a photo of the specials board so you can choose before we get there.", demoAttachment(id: 501, fileName: "menu-specials.jpg", mimeType: "image/jpeg", megabytes: 2)),
                (true, "The ravioli looks good. Also, I need to talk through the archive export flow.", nil),
                (false, "Bring the notes. I can sanity-check whether the legal metadata reads clearly.", nil),
                (true, "Great. The tricky part is making the PDF useful without making it feel too technical.", nil),
                (false, "Maybe start with a clean cover page, then messages in order. People can always use the raw data files later.", nil),
                (true, "Exactly. I want the visual export to be readable first.", nil),
                (false, "Readable and predictable. No weird page cuts through messages.", nil),
                (true, "That one is on my bug list now.", nil),
                (false, "Good. I will bring examples from a few long threads.", nil),
                (true, "Thanks. I will bring the latest build so we can export from demo mode safely.", nil),
                (false, "Love that. No real data while testing.", nil),
                (true, "See you at noon.", nil),
                (false, "See you soon.", nil)
            ]
        )
        
        simulatedMessages[2] = makeSimulatedThread(
            baseID: 200,
            senderID: "bob.jones@icloud.com",
            startDate: now.addingTimeInterval(-oneDay * 2),
            minutesBetweenMessages: 13,
            lines: [
                (false, "Can you send me the PDF contract for the project?", nil),
                (true, "Yes. I am reviewing the final clause list now.", nil),
                (false, "No rush, but I need to attach it to the vendor packet by end of day.", nil),
                (true, "Understood. The main change is the storage retention language.", nil),
                (false, "That is the section legal flagged yesterday.", nil),
                (true, "Here is the signed contract copy for the synthetic demo thread.", demoAttachment(id: 502, fileName: "contract-final.pdf", mimeType: "application/pdf", megabytes: 14)),
                (false, "Received. I will process the payment today.", nil),
                (true, "Great. Please confirm once accounting has the invoice reference.", nil),
                (false, "They just asked whether the export manifest is included.", nil),
                (true, "For MVP we have a cover manifest in the PDF. The deterministic sidecar manifest is next.", nil),
                (false, "Makes sense. The cover page is enough for the walkthrough.", nil),
                (true, "I also want CSV and JSON to use the same message ordering.", nil),
                (false, "That will help reviewers compare outputs.", nil),
                (true, "Exactly. Same records, different presentation.", nil),
                (false, "I will note that in the acceptance criteria.", nil),
                (true, "Thanks. Send over any wording changes before the review.", nil),
                (false, "Will do.", nil)
            ]
        )
        
        simulatedMessages[3] = makeSimulatedThread(
            baseID: 300,
            senderID: "Mom",
            startDate: now.addingTimeInterval(-oneDay * 12),
            minutesBetweenMessages: 9,
            lines: [
                (false, "Mom: What are we doing for Father's day next week?", nil),
                (false, "Sister: Let's do a backyard BBQ. I can bring potato salad.", nil),
                (true, "Sounds great. I can grill the steaks and bring drinks.", nil),
                (false, "Bob Jones: I can pick up charcoal and ice.", nil),
                (false, "Mom: Please make sure there are vegetarian sides too.", nil),
                (true, "Absolutely. Corn, salad, grilled peppers, and veggie skewers.", nil),
                (false, "Sister: I made a shared shopping list for everyone.", nil),
                (true, "Check out this synthetic grill photo from the demo fixture.", demoAttachment(id: 503, fileName: "demo-grill.png", mimeType: "image/png", megabytes: 6)),
                (false, "Mom: Oh wow, that looks huge. We will need a lot of charcoal.", nil),
                (true, "I will pick up the charcoal on Friday.", nil),
                (false, "Bob Jones: I can bring folding chairs.", nil),
                (false, "Sister: Do we need dessert?", nil),
                (true, "Yes, but something easy. Maybe berries and ice cream.", nil),
                (false, "Mom: Your father would like that.", nil),
                (true, "I will also print the old family photos for the table.", nil),
                (false, "Sister: Nice. Please label the dates if you can.", nil),
                (true, "Good idea. I can make a small archive packet.", nil),
                (false, "Bob Jones: This has become very official.", nil),
                (true, "Only mildly official. Still mostly about food.", nil),
                (false, "Mom: I am adding lemonade to the list.", nil),
                (true, "Perfect. I will send a final plan Friday morning.", nil),
                (false, "Sister: Works for me.", nil)
            ]
        )
        
        simulatedMessages[4] = makeSimulatedThread(
            baseID: 400,
            senderID: "Apple Support",
            startDate: now.addingTimeInterval(-oneDay * 20),
            minutesBetweenMessages: 5,
            lines: [
                (false, "Your support request has been registered. A representative will be with you shortly.", nil),
                (false, "How can I help you today?", nil),
                (true, "I am testing a local export workflow and want to confirm permissions language.", nil),
                (false, "I can help with general guidance about local macOS permissions.", nil),
                (true, "The app should explain Full Disk Access without reading any real data during demo testing.", nil),
                (false, "That sounds like a good separation. Demo data should remain synthetic.", nil),
                (true, "Exactly. The app has a simulated source for this.", nil),
                (false, "Then the onboarding copy should make the distinction clear.", nil),
                (true, "Agreed. The demo lets people try export behavior before granting anything.", nil),
                (false, "That is helpful for privacy-sensitive review.", nil),
                (true, "I also want the generated PDF to page cleanly on A4.", nil),
                (false, "Clean page boundaries are important for printing and filing.", nil),
                (true, "The exporter now lays out page containers before rendering.", nil),
                (false, "Great. Please run a build after changing the export renderer.", nil),
                (true, "Already on the checklist.", nil),
                (false, "Thanks for contacting support.", nil)
            ]
        )
    }

    private func makeSimulatedThread(
        baseID: Int64,
        senderID: String,
        startDate: Date,
        minutesBetweenMessages: Int,
        lines: [(isFromMe: Bool, text: String, attachment: AttachmentItem?)]
    ) -> [MessageItem] {
        lines.enumerated().map { index, line in
            MessageItem(
                messageID: baseID + Int64(index + 1),
                text: line.text,
                date: startDate.addingTimeInterval(TimeInterval(index * minutesBetweenMessages * 60)),
                isFromMe: line.isFromMe,
                senderID: line.isFromMe ? "me" : senderIDForDemoLine(line.text, fallback: senderID),
                attachments: line.attachment.map { [$0] } ?? []
            )
        }
    }

    private func senderIDForDemoLine(_ text: String, fallback: String) -> String {
        if text.hasPrefix("Mom:") { return "Mom" }
        if text.hasPrefix("Sister:") { return "Sister" }
        if text.hasPrefix("Bob Jones:") { return "Bob Jones" }
        return fallback
    }

    private func demoAttachment(id: Int64, fileName: String, mimeType: String, megabytes: Int64) -> AttachmentItem {
        AttachmentItem(
            attachmentID: id,
            guid: "demo-att-\(id)",
            filename: "/SyntheticFixtures/\(fileName)",
            mimeType: mimeType,
            totalBytes: megabytes * 1024 * 1024
        )
    }
}
