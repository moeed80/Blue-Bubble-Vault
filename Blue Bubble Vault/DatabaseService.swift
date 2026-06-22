//
//  DatabaseService.swift
//  Blue Bubble Vault
//
//  Created by Antigravity on 6/5/26.
//

import Foundation
import SQLite3

public struct ChatThread: Identifiable, Hashable {
    public var id: Int64 { chatID }
    public let chatID: Int64
    public let guid: String
    public let chatIdentifier: String
    public let displayName: String
    public let messageCount: Int
    public let participantHandles: String
    
    public var title: String {
        if !displayName.isEmpty {
            return displayName
        }
        return chatIdentifier
    }
}

public struct AttachmentItem: Identifiable, Hashable {
    public var id: Int64 { attachmentID }
    public let attachmentID: Int64
    public let guid: String
    public let filename: String
    public let mimeType: String
    public let totalBytes: Int64
    
    public var fileURL: URL? {
        if filename.isEmpty { return nil }
        // Clean prefix if it uses ~/ or relative paths
        var path = filename
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            path = path.replacingCharacters(in: ..<path.index(path.startIndex, offsetBy: 2), with: home + "/")
        }
        return URL(fileURLWithPath: path)
    }
}

public struct MessageItem: Identifiable, Hashable {
    public var id: Int64 { messageID }
    public let messageID: Int64
    public let text: String
    public let date: Date
    public let isFromMe: Bool
    public let senderID: String
    public var attachments: [AttachmentItem]
}

public final class DatabaseService {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    
    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return db != nil
    }
    
    public init() {}
    
    deinit {
        close()
    }

    private func closeUnlocked() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    /// Safely extracts a String from a statement column, handling null pointers.
    private func getString(from statement: OpaquePointer?, at index: Int32) -> String {
        guard let statement = statement,
              let cString = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: cString)
    }
    
    /// Opens the database at the specified path in read-only mode.
    public func open(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        closeUnlocked()
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        if result != SQLITE_OK {
            if let dbPointer = db, let errorMsg = sqlite3_errmsg(dbPointer) {
                let str = String(cString: errorMsg)
                print("Failed to open database at \(path): \(str)")
            } else {
                print("Failed to open database at \(path) with an unknown error.")
            }
            closeUnlocked()
            return false
        }
        return true
    }
    
    /// Closes the active database connection.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeUnlocked()
    }
    
    /// Cultivates all active chat threads from the database.
    public func fetchChatThreads() -> [ChatThread] {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return [] }
        
        let query = """
        SELECT 
            c.ROWID as chat_id,
            c.guid as chat_guid,
            COALESCE(c.chat_identifier, '') as chat_identifier,
            COALESCE(c.display_name, '') as display_name,
            COUNT(m.ROWID) as message_count,
            (SELECT GROUP_CONCAT(h.id, ', ') FROM chat_handle_join chj JOIN handle h ON chj.handle_id = h.ROWID WHERE chj.chat_id = c.ROWID) as participant_handles
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON cmj.message_id = m.ROWID
        GROUP BY c.ROWID
        ORDER BY message_count DESC;
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("Failed to prepare fetchChatThreads query: \(getErrorMessage())")
            return []
        }
        
        defer {
            sqlite3_finalize(statement)
        }
        
        var threads: [ChatThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let chatID = sqlite3_column_int64(statement, 0)
            let guid = getString(from: statement, at: 1)
            let chatIdentifier = getString(from: statement, at: 2)
            let displayName = getString(from: statement, at: 3)
            let messageCount = Int(sqlite3_column_int(statement, 4))
            let participantHandles = getString(from: statement, at: 5)
            
            threads.append(ChatThread(
                chatID: chatID,
                guid: guid,
                chatIdentifier: chatIdentifier,
                displayName: displayName,
                messageCount: messageCount,
                participantHandles: participantHandles
            ))
        }
        
        return threads
    }
    
    /// Fetches messages for a specific chat, filtered by optional date range, keywords, and media toggle.
    public func fetchMessages(
        chatID: Int64,
        startDate: Date?,
        endDate: Date?,
        keyword: String?,
        includeMedia: Bool
    ) -> [MessageItem] {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return [] }
        
        var query = """
        SELECT 
            m.ROWID as message_id,
            COALESCE(m.text, '') as message_text,
            m.date as message_date,
            m.is_from_me as is_from_me,
            COALESCE(h.id, '') as sender_id,
            a.ROWID as attachment_id,
            COALESCE(a.guid, '') as attachment_guid,
            COALESCE(a.filename, '') as attachment_filename,
            COALESCE(a.mime_type, '') as attachment_mime,
            COALESCE(a.total_bytes, 0) as attachment_bytes,
            m.attributedBody as message_attributed_body,
            COALESCE(m.associated_message_type, 0) as associated_message_type,
            COALESCE(m.associated_message_guid, '') as associated_message_guid
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        """
        
        if includeMedia {
            query += """
            
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            """
        } else {
            query += """
            
            LEFT JOIN (SELECT NULL as ROWID, NULL as guid, NULL as filename, NULL as mime_type, NULL as total_bytes) a ON 1=0
            """
        }
        
        query += "\nWHERE cmj.chat_id = ?"
        
        // Add Date constraints
        if startDate != nil {
            query += " AND m.date >= ?"
        }
        if endDate != nil {
            query += " AND m.date <= ?"
        }
        
        query += "\nORDER BY m.date ASC;"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("Failed to prepare fetchMessages query: \(getErrorMessage())")
            return []
        }
        
        defer {
            sqlite3_finalize(statement)
        }
        
        var bindIndex: Int32 = 1
        sqlite3_bind_int64(statement, bindIndex, chatID)
        bindIndex += 1
        
        if let start = startDate {
            let startNano = Int64(start.timeIntervalSinceReferenceDate * 1_000_000_000)
            sqlite3_bind_int64(statement, bindIndex, startNano)
            bindIndex += 1
        }
        
        if let end = endDate {
            let endNano = Int64(end.timeIntervalSinceReferenceDate * 1_000_000_000)
            sqlite3_bind_int64(statement, bindIndex, endNano)
            bindIndex += 1
        }
        
        let normalizedKeyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var messagesMap: [Int64: MessageItem] = [:]
        var messagesOrdered: [Int64] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqlite3_column_int64(statement, 0)
            let associatedMessageType = sqlite3_column_int(statement, 11)
            let associatedMessageGUID = getString(from: statement, at: 12)
            
            // Get the text properly
            let textColumnIndex = 1
            let blobColumnIndex = 10

            var text = ""

            // First try to get the regular text column
            if let textPtr = sqlite3_column_text(statement, Int32(textColumnIndex)) {
                text = String(cString: textPtr)
            }

            // Some real Messages rows keep body text in attributedBody. Avoid Objective-C
            // unarchiving here because malformed or newer blobs can terminate the process.
            if text.isEmpty {
                if let blobBytes = sqlite3_column_blob(statement, Int32(blobColumnIndex)) {
                    let blobLength = Int(sqlite3_column_bytes(statement, Int32(blobColumnIndex)))
                    if blobLength > 0 {
                        let rawData = Data(bytes: blobBytes, count: blobLength)
                        text = extractReadableText(fromAttributedBody: rawData)
                    }
                }
            }

            if let tapbackText = tapbackDescription(for: associatedMessageType) {
                text = tapbackText
            } else if let tapbackText = tapbackDescription(forMarker: text) {
                text = tapbackText
            } else if !associatedMessageGUID.isEmpty,
                      let associatedText = associatedMessageDescription(forPayload: text) {
                text = associatedText
            } else if associatedMessageType != 0 {
                text = "Reacted to a message"
            } else if isAppleMessageMetadata(text) {
                text = ""
            }

            if let normalizedKeyword, !normalizedKeyword.isEmpty,
               !text.localizedCaseInsensitiveContains(normalizedKeyword) {
                continue
            }
            
            // Convert nanoseconds to Date
            let rawDate = sqlite3_column_int64(statement, 2)
            let dateInterval = rawDate > 10_000_000_000 ? Double(rawDate) / 1_000_000_000.0 : Double(rawDate)
            let date = Date(timeIntervalSinceReferenceDate: dateInterval)
            
            let isFromMe = sqlite3_column_int(statement, 3) != 0
            let senderID = getString(from: statement, at: 4)
            
            let hasAttachment = sqlite3_column_type(statement, 5) != SQLITE_NULL
            
            if messagesMap[messageID] == nil {
                let msg = MessageItem(
                    messageID: messageID,
                    text: text,
                    date: date,
                    isFromMe: isFromMe,
                    senderID: senderID,
                    attachments: []
                )
                messagesMap[messageID] = msg
                messagesOrdered.append(messageID)
            }
            
            if hasAttachment && includeMedia {
                let attachmentID = sqlite3_column_int64(statement, 5)
                let attGuid = getString(from: statement, at: 6)
                let attFilename = getString(from: statement, at: 7)
                let attMime = getString(from: statement, at: 8)
                let attBytes = sqlite3_column_int64(statement, 9)
                
                let attachment = AttachmentItem(
                    attachmentID: attachmentID,
                    guid: attGuid,
                    filename: attFilename,
                    mimeType: attMime,
                    totalBytes: attBytes
                )
                
                messagesMap[messageID]?.attachments.append(attachment)
            }
        }
        
        return messagesOrdered.compactMap { messagesMap[$0] }
    }
    
    /// Queries the total size (bytes) of attachments for a chat thread matching the criteria.
    public func fetchAttachmentTotalBytes(
        chatID: Int64,
        startDate: Date?,
        endDate: Date?
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return 0 }
        
        var query = """
        SELECT SUM(a.total_bytes)
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        JOIN message_attachment_join maj ON m.ROWID = maj.message_id
        JOIN attachment a ON maj.attachment_id = a.ROWID
        WHERE cmj.chat_id = ?
        """
        
        if startDate != nil {
            query += " AND m.date >= ?"
        }
        if endDate != nil {
            query += " AND m.date <= ?"
        }
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("Failed to prepare fetchAttachmentTotalBytes query: \(getErrorMessage())")
            return 0
        }
        
        defer {
            sqlite3_finalize(statement)
        }
        
        var bindIndex: Int32 = 1
        sqlite3_bind_int64(statement, bindIndex, chatID)
        bindIndex += 1
        
        if let start = startDate {
            let startNano = Int64(start.timeIntervalSinceReferenceDate * 1_000_000_000)
            sqlite3_bind_int64(statement, bindIndex, startNano)
            bindIndex += 1
        }
        
        if let end = endDate {
            let endNano = Int64(end.timeIntervalSinceReferenceDate * 1_000_000_000)
            sqlite3_bind_int64(statement, bindIndex, endNano)
            bindIndex += 1
        }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            return sqlite3_column_int64(statement, 0)
        }
        
        return 0
    }
    
    private func getErrorMessage() -> String {
        guard let db = db else { return "No open database" }
        if let err = sqlite3_errmsg(db) {
            return String(cString: err)
        }
        return "Unknown error"
    }

    private func extractReadableText(fromAttributedBody data: Data) -> String {
        var candidates = [String(decoding: data, as: UTF8.self)]
        if let bomEncodedString = decodeExplicitUTF16Data(data) {
            candidates.append(bomEncodedString)
        }

        return candidates
            .flatMap(readableRuns(in:))
            .max { readableTextScore($0) < readableTextScore($1) } ?? ""
    }

    private func decodeExplicitUTF16Data(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }

        let first = data[data.startIndex]
        let second = data[data.index(after: data.startIndex)]

        if first == 0xFF && second == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if first == 0xFE && second == 0xFF {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }

        return nil
    }

    private func readableRuns(in string: String) -> [String] {
        var runs: [String] = []
        var current = String.UnicodeScalarView()

        func flushCurrentRun() {
            let value = sanitizeReadableRun(String(current).trimmingCharacters(in: .whitespacesAndNewlines))
            current.removeAll(keepingCapacity: true)

            guard isLikelyReadableText(value),
                  !isAppleMessageMetadata(value) else {
                return
            }
            runs.append(value)
        }

        for scalar in string.unicodeScalars {
            if scalar == "\u{FFFD}" {
                flushCurrentRun()
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.alphanumerics.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar) {
                current.append(scalar)
            } else {
                flushCurrentRun()
            }
        }

        flushCurrentRun()
        return runs
    }

    private func isLikelyReadableText(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { return false }

        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let emoji = scalars.filter(isEmojiScalar).count
        let separators = scalars.filter { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0) }.count

        guard letters > 0 || emoji > 0 else { return false }

        let meaningfulCharacters = letters + digits + separators + emoji
        guard Double(meaningfulCharacters) / Double(scalars.count) > 0.8 else { return false }

        if scalars.count <= 2, digits > 0, emoji == 0 {
            return false
        }

        if digits > letters + emoji + separators {
            return false
        }

        return true
    }

    private func readableTextScore(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { score, scalar in
            if CharacterSet.letters.contains(scalar) { return score + 3 }
            if isEmojiScalar(scalar) { return score + 3 }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return score + 2 }
            if CharacterSet.decimalDigits.contains(scalar) { return score + 1 }
            if CharacterSet.punctuationCharacters.contains(scalar) { return score + 1 }
            return score
        }
    }

    private func sanitizeReadableRun(_ value: String) -> String {
        var sanitized = value
        for token in appleMessageMetadataTokens {
            sanitized = sanitized.replacingOccurrences(of: token, with: "")
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAppleMessageMetadata(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if appleMessageMetadataTokens.contains(trimmed) { return true }
        if tapbackMarkerTokens.contains(trimmed) { return true }
        if trimmed.hasPrefix("__kIM") || trimmed.hasPrefix("kIM") { return true }
        if trimmed.hasPrefix("NS") && !trimmed.contains(" ") { return true }
        if trimmed.hasPrefix("+k") || trimmed.hasPrefix("-k") { return true }
        return false
    }

    private var appleMessageMetadataTokens: Set<String> {
        [
            "__kIMMessagePartAttributeName",
            "__kIMFileTransferGUIDAttributeName",
            "__kIMMentionConfirmedMention",
            "NSString",
            "NSDictionary",
            "NSMutableDictionary",
            "NSObject",
            "NSNumber",
            "NSAttributedString",
            "NSFont",
            "NSColor",
            "NSParagraphStyle",
            "streamtyped",
            "typedstream"
        ]
    }

    private var tapbackMarkerTokens: Set<String> {
        [
            "+kLoved", "+kLiked", "+kDisliked", "+kLaughed", "+kEmphasized", "+kQuestioned",
            "-kLoved", "-kLiked", "-kDisliked", "-kLaughed", "-kEmphasized", "-kQuestioned"
        ]
    }

    private func isTapbackMarker(_ value: String) -> Bool {
        tapbackMarkerTokens.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func tapbackDescription(forMarker value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "+kLoved": return "Loved a message"
        case "+kLiked": return "Liked a message"
        case "+kDisliked": return "Disliked a message"
        case "+kLaughed": return "Laughed at a message"
        case "+kEmphasized": return "Emphasized a message"
        case "+kQuestioned": return "Questioned a message"
        case "-kLoved": return "Removed a love from a message"
        case "-kLiked": return "Removed a like from a message"
        case "-kDisliked": return "Removed a dislike from a message"
        case "-kLaughed": return "Removed a laugh from a message"
        case "-kEmphasized": return "Removed emphasis from a message"
        case "-kQuestioned": return "Removed a question from a message"
        default: return nil
        }
    }

    private func tapbackDescription(for associatedMessageType: Int32) -> String? {
        switch associatedMessageType {
        case 2000: return "Loved a message"
        case 2001: return "Liked a message"
        case 2002: return "Disliked a message"
        case 2003: return "Laughed at a message"
        case 2004: return "Emphasized a message"
        case 2005: return "Questioned a message"
        case 3000: return "Removed a love from a message"
        case 3001: return "Removed a like from a message"
        case 3002: return "Removed a dislike from a message"
        case 3003: return "Removed a laugh from a message"
        case 3004: return "Removed emphasis from a message"
        case 3005: return "Removed a question from a message"
        default: return nil
        }
    }

    private func associatedMessageDescription(forPayload value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Reacted to a message" }

        if isAppleMessageMetadata(trimmed) {
            return "Reacted to a message"
        }

        if trimmed.hasPrefix("+:") || trimmed.hasPrefix("-:") {
            let payload = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return "Reacted to a message" }
            return trimmed.hasPrefix("-:") ? "Removed reaction \(payload)" : "Reacted with \(payload)"
        }

        if trimmed.range(of: #"^[+-]\d+$"#, options: .regularExpression) != nil {
            return "Reacted to a message"
        }

        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            return "Reacted to a message"
        }

        return nil
    }

    private func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2300...0x23FF:
            return true
        default:
            return false
        }
    }
}
