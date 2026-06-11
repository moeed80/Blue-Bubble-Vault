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
    
    public var isOpen: Bool {
        return db != nil
    }
    
    public init() {}
    
    deinit {
        close()
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
        close()
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        if result != SQLITE_OK {
            if let dbPointer = db, let errorMsg = sqlite3_errmsg(dbPointer) {
                let str = String(cString: errorMsg)
                print("Failed to open database at \(path): \(str)")
            } else {
                print("Failed to open database at \(path) with an unknown error.")
            }
            close()
            return false
        }
        return true
    }
    
    /// Closes the active database connection.
    public func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    /// Cultivates all active chat threads from the database.
    public func fetchChatThreads() -> [ChatThread] {
        guard let db = db else { return [] }
        
        let query = """
        SELECT 
            c.ROWID as chat_id,
            c.guid as chat_guid,
            COALESCE(c.chat_identifier, '') as chat_identifier,
            COALESCE(c.display_name, '') as display_name,
            COUNT(m.ROWID) as message_count
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
            
            threads.append(ChatThread(
                chatID: chatID,
                guid: guid,
                chatIdentifier: chatIdentifier,
                displayName: displayName,
                messageCount: messageCount
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
            m.attributedBody as message_attributed_body
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
        
        // Add Keyword constraints
        if let key = keyword, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query += " AND (m.text LIKE ? OR m.attributedBody IS NOT NULL)"
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
        
        if let key = keyword, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sqlite3_bind_text(statement, bindIndex, "%\(key)%", -1, nil)
            bindIndex += 1
        }
        
        var messagesMap: [Int64: MessageItem] = [:]
        var messagesOrdered: [Int64] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqlite3_column_int64(statement, 0)
            
            // Get the text properly
            let textColumnIndex = 1
            let blobColumnIndex = 10

            var text = ""

            // First try to get the regular text column
            if let textPtr = sqlite3_column_text(statement, Int32(textColumnIndex)) {
                text = String(cString: textPtr)
            }

            // If text is empty and we have an attributedBody, decode the legacy typedstream
            // If text is empty and we have an attributedBody, decode the legacy typedstream safely
            if text.isEmpty {
                if let blobBytes = sqlite3_column_blob(statement, Int32(blobColumnIndex)) {
                    let blobLength = Int(sqlite3_column_bytes(statement, Int32(blobColumnIndex)))
                    if blobLength > 0 {
                        let rawData = Data(bytes: blobBytes, count: blobLength)
                        
                        // Bypass the static deprecation warning by fetching the class dynamically at runtime
                        if let legacyUnarchiverClass: AnyObject = NSClassFromString("NSUnarchiver") {
                            let selector = #selector(NSKeyedUnarchiver.unarchiveObject(with:))
                            if legacyUnarchiverClass.responds(to: selector) {
                                if let unmanagedResult = legacyUnarchiverClass.perform(selector, with: rawData) {
                                    if let attributedString = unmanagedResult.takeUnretainedValue() as? NSAttributedString {
                                        text = attributedString.string
                                    }
                                }
                            }
                        }
                    }
                }
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
}
