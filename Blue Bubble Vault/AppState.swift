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
        
    /// Checks the current FDA permission status, scans for active databases, and updates source lists.
    public func checkPermissionsAndScanSources() {
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
    // If display name is set, use it
    if !thread.displayName.isEmpty {
        return thread.displayName
    }
    
    // If chat identifier starts with "chat" (multi-user thread), resolve participant handles
    if thread.chatIdentifier.starts(with: "chat") && !thread.participantHandles.isEmpty {
        let handles = thread.participantHandles.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        var resolvedNamesList: [String] = []
        
        for handle in handles {
            // Try to resolve the handle to a contact name
            if let resolvedName = resolvedNames[handle] {
                resolvedNamesList.append(resolvedName)
            } else {
                // Fallback to the raw handle if no resolution available
                resolvedNamesList.append(handle)
            }
        }
        
        return resolvedNamesList.joined(separator: ", ")
    }
    
    // Default fallback to chat identifier
    return thread.chatIdentifier
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
            ChatThread(chatID: 1, guid: "sim-chat-1", chatIdentifier: "+1 (555) 019-2834", displayName: "Alice Smith", messageCount: 4, participantHandles: "+1 (555) 019-2834"),
            ChatThread(chatID: 2, guid: "sim-chat-2", chatIdentifier: "bob.jones@icloud.com", displayName: "Bob Jones", messageCount: 3, participantHandles: "bob.jones@icloud.com"),
            ChatThread(chatID: 3, guid: "sim-chat-3", chatIdentifier: "chat8394850123", displayName: "Family Group", messageCount: 5, participantHandles: "Alice Smith, Bob Jones, Mom, Sister"),
            ChatThread(chatID: 4, guid: "sim-chat-4", chatIdentifier: "+1 (800) 424-9090", displayName: "Apple Support", messageCount: 2, participantHandles: "+1 (800) 424-9090")
        ]
        
        let now = Date()
        let oneDay: TimeInterval = 24 * 60 * 60
        
        simulatedMessages[1] = [
            MessageItem(messageID: 101, text: "Hey! Are we still on for lunch today?", date: now.addingTimeInterval(-oneDay * 5), isFromMe: false, senderID: "+1 (555) 019-2834", attachments: []),
            MessageItem(messageID: 102, text: "Yes, definitely! Same Italian place as usual?", date: now.addingTimeInterval(-oneDay * 5 + 300), isFromMe: true, senderID: "me", attachments: []),
            MessageItem(messageID: 103, text: "Yep! I took a photo of the new menu changes. Check this out.", date: now.addingTimeInterval(-oneDay * 5 + 600), isFromMe: false, senderID: "+1 (555) 019-2834", attachments: [
                AttachmentItem(attachmentID: 501, guid: "att-1", filename: "~/Downloads/menu.jpg", mimeType: "image/jpeg", totalBytes: 1024 * 1024 * 2)
            ]),
            MessageItem(messageID: 104, text: "Looks delicious! See you at 12:30.", date: now.addingTimeInterval(-oneDay * 5 + 900), isFromMe: true, senderID: "me", attachments: [])
        ]
        
        simulatedMessages[2] = [
            MessageItem(messageID: 201, text: "Can you send me the PDF contract for the project?", date: now.addingTimeInterval(-oneDay * 2), isFromMe: false, senderID: "bob.jones@icloud.com", attachments: []),
            MessageItem(messageID: 202, text: "Here is the signed contract copy.", date: now.addingTimeInterval(-oneDay * 2 + 1200), isFromMe: true, senderID: "me", attachments: [
                AttachmentItem(attachmentID: 502, guid: "att-2", filename: "~/Documents/Contract_Final.pdf", mimeType: "application/pdf", totalBytes: 1024 * 1024 * 14)
            ]),
            MessageItem(messageID: 203, text: "Thanks, received it. I will process the payment today.", date: now.addingTimeInterval(-oneDay * 2 + 3600), isFromMe: false, senderID: "bob.jones@icloud.com", attachments: [])
        ]
        
        simulatedMessages[3] = [
            MessageItem(messageID: 301, text: "Mom: What are we doing for Father's day next week?", date: now.addingTimeInterval(-oneDay * 12), isFromMe: false, senderID: "Mom", attachments: []),
            MessageItem(messageID: 302, text: "Sis: Let's do a backyard BBQ. I can bring potato salad.", date: now.addingTimeInterval(-oneDay * 12 + 600), isFromMe: false, senderID: "Sister", attachments: []),
            MessageItem(messageID: 303, text: "Sounds great, I'll grill the steaks. Check out this grill I bought yesterday!", date: now.addingTimeInterval(-oneDay * 12 + 900), isFromMe: true, senderID: "me", attachments: [
                AttachmentItem(attachmentID: 503, guid: "att-3", filename: "~/Pictures/NewGrill.png", mimeType: "image/png", totalBytes: 1024 * 1024 * 6)
            ]),
            MessageItem(messageID: 304, text: "Mom: Oh wow, that looks huge! We'll need a lot of charcoal.", date: now.addingTimeInterval(-oneDay * 12 + 1800), isFromMe: false, senderID: "Mom", attachments: []),
            MessageItem(messageID: 305, text: "I'll pick up the charcoal on Friday.", date: now.addingTimeInterval(-oneDay * 11), isFromMe: true, senderID: "me", attachments: [])
        ]
        
        simulatedMessages[4] = [
            MessageItem(messageID: 401, text: "Your support request has been registered. A representative will be with you shortly.", date: now.addingTimeInterval(-oneDay * 20), isFromMe: false, senderID: "Apple Support", attachments: []),
            MessageItem(messageID: 402, text: "How can I help you today?", date: now.addingTimeInterval(-oneDay * 20 + 60), isFromMe: false, senderID: "Apple Support", attachments: [])
        ]
    }
}
