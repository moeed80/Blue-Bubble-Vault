import SQLite3
import XCTest
@testable import Blue_Bubble_Vault

@MainActor
final class DatabaseServiceFixtureTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueBubbleVaultFixtureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        databaseURL = temporaryDirectory.appendingPathComponent("synthetic-chat.db")
        try SyntheticMessagesFixture.createDatabase(at: databaseURL)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        databaseURL = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testFetchChatThreadsUsesSyntheticFixture() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let threads = service.fetchChatThreads()

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.chatID, 10)
        XCTAssertEqual(threads.first?.chatIdentifier, "+15550192834")
        XCTAssertEqual(threads.first?.messageCount, 3)
        XCTAssertEqual(threads.first?.participantHandles, "+15550192834")
    }

    func testFetchMessagesFiltersByDateAndExcludesMedia() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.middleMessageDate,
            endDate: SyntheticMessagesFixture.middleMessageDate.addingTimeInterval(60),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [101])
        XCTAssertEqual(messages.first?.text, "Need <signed> & ready")
        XCTAssertEqual(messages.first?.attachments, [])
    }

    func testFetchMessagesIncludesMediaAndAttachmentSizeEstimate() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: nil,
            endDate: nil,
            keyword: "Image",
            includeMedia: true
        )
        let attachmentBytes = service.fetchAttachmentTotalBytes(
            chatID: 10,
            startDate: nil,
            endDate: nil
        )

        XCTAssertEqual(messages.map(\.messageID), [102])
        XCTAssertEqual(messages.first?.attachments.count, 1)
        XCTAssertEqual(messages.first?.attachments.first?.filename, "~/Library/Messages/Attachments/synthetic/photo.jpg")
        XCTAssertEqual(attachmentBytes, 4096)
    }
}

private enum SyntheticMessagesFixture {
    static let firstMessageDate = Date(timeIntervalSinceReferenceDate: 1_000)
    static let middleMessageDate = Date(timeIntervalSinceReferenceDate: 2_000)
    static let attachmentMessageDate = Date(timeIntervalSinceReferenceDate: 3_000)

    static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        guard let db else {
            throw FixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        try execute(
            db,
            """
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                chat_identifier TEXT,
                display_name TEXT
            );
            CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY,
                id TEXT
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                text TEXT,
                date INTEGER,
                is_from_me INTEGER,
                handle_id INTEGER,
                attributedBody BLOB
            );
            CREATE TABLE chat_message_join (
                chat_id INTEGER,
                message_id INTEGER
            );
            CREATE TABLE chat_handle_join (
                chat_id INTEGER,
                handle_id INTEGER
            );
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                filename TEXT,
                mime_type TEXT,
                total_bytes INTEGER
            );
            CREATE TABLE message_attachment_join (
                message_id INTEGER,
                attachment_id INTEGER
            );
            """
        )

        try execute(
            db,
            """
            INSERT INTO chat (ROWID, guid, chat_identifier, display_name)
            VALUES (10, 'synthetic-chat-guid', '+15550192834', '');
            INSERT INTO handle (ROWID, id)
            VALUES (1, '+15550192834');
            INSERT INTO chat_handle_join (chat_id, handle_id)
            VALUES (10, 1);
            """
        )

        try insertMessage(db, id: 100, text: "Old planning note", date: firstMessageDate, isFromMe: false, handleID: 1)
        try insertMessage(db, id: 101, text: "Need <signed> & ready", date: middleMessageDate, isFromMe: true, handleID: nil)
        try insertMessage(db, id: 102, text: "Image attached", date: attachmentMessageDate, isFromMe: false, handleID: 1)

        try execute(
            db,
            """
            INSERT INTO chat_message_join (chat_id, message_id)
            VALUES (10, 100), (10, 101), (10, 102);
            INSERT INTO attachment (ROWID, guid, filename, mime_type, total_bytes)
            VALUES (500, 'synthetic-attachment-guid', '~/Library/Messages/Attachments/synthetic/photo.jpg', 'image/jpeg', 4096);
            INSERT INTO message_attachment_join (message_id, attachment_id)
            VALUES (102, 500);
            """
        )
    }

    private static func insertMessage(_ db: OpaquePointer,
                                      id: Int,
                                      text: String,
                                      date: Date,
                                      isFromMe: Bool,
                                      handleID: Int?) throws {
        let handleValue = handleID.map(String.init) ?? "NULL"
        let nanoseconds = Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
        try execute(
            db,
            """
            INSERT INTO message (ROWID, text, date, is_from_me, handle_id, attributedBody)
            VALUES (\(id), '\(text.replacingOccurrences(of: "'", with: "''"))', \(nanoseconds), \(isFromMe ? 1 : 0), \(handleValue), NULL);
            """
        )
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw FixtureError.sqlFailed(message)
        }
    }

    enum FixtureError: Error {
        case openFailed
        case sqlFailed(String)
    }
}
