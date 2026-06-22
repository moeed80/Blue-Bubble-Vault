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
        XCTAssertEqual(threads.first?.messageCount, 14)
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

    func testFetchMessagesDoesNotMatchEveryAttributedBodyRowForKeyword() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: nil,
            endDate: nil,
            keyword: "signed",
            includeMedia: true
        )

        XCTAssertEqual(messages.map(\.messageID), [101])
    }

    func testFetchMessagesCanFilterTextStoredOnlyInAttributedBody() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: nil,
            endDate: nil,
            keyword: "settlement",
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [103])
        XCTAssertEqual(messages.first?.text, "Hidden settlement phrase")
    }

    func testFetchMessagesKeywordDoesNotMatchDiscardedMetadataText() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: nil,
            endDate: nil,
            keyword: "streamtyped",
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [])
    }

    func testDatePickerEndDateIncludesWholeSelectedDay() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let selectedEndDate = calendar.startOfDay(for: SyntheticMessagesFixture.attachmentMessageDate)
        let inclusiveEndDate = AppState.inclusiveEndOfSelectedDay(for: selectedEndDate, calendar: calendar)

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: nil,
            endDate: inclusiveEndDate,
            keyword: "settlement",
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [103])
    }

    func testFetchMessagesDoesNotDisplayUTF16InterpretationOfBinaryAttributedBody() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.binaryBlobMessageDate,
            endDate: SyntheticMessagesFixture.binaryBlobMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [105])
        XCTAssertEqual(messages.first?.text, "")
    }

    func testFetchMessagesDoesNotDisplayAppleAttributedBodyMetadata() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.metadataBlobMessageDate,
            endDate: SyntheticMessagesFixture.metadataBlobMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [106])
        XCTAssertEqual(messages.first?.text, "")
    }

    func testFetchMessagesShowsTapbackDescriptionInsteadOfRawMarker() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.tapbackMessageDate,
            endDate: SyntheticMessagesFixture.tapbackMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [107])
        XCTAssertEqual(messages.first?.text, "Liked a message")
    }

    func testFetchMessagesShowsTapbackDescriptionWhenOnlyRawMarkerExists() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.rawTapbackMessageDate,
            endDate: SyntheticMessagesFixture.rawTapbackMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [109])
        XCTAssertEqual(messages.first?.text, "Liked a message")
    }


    func testFetchMessagesPreservesEmojiOnlyAttributedBodyText() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.emojiMessageDate,
            endDate: SyntheticMessagesFixture.emojiMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [108])
        XCTAssertEqual(messages.first?.text, "\u{1F44D}\u{1F44D}")
    }

    func testFetchMessagesDoesNotDisplayTypedstreamHeader() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.typedstreamMessageDate,
            endDate: SyntheticMessagesFixture.typedstreamMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [110])
        XCTAssertEqual(messages.first?.text, "")
    }

    func testFetchMessagesDisplaysAssociatedCustomReactionReadably() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.customReactionMessageDate,
            endDate: SyntheticMessagesFixture.customReactionMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [111])
        XCTAssertEqual(messages.first?.text, "Reacted with Awesome!")
    }

    func testFetchMessagesDisplaysAssociatedNumericReactionReadably() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.numericReactionMessageDate,
            endDate: SyntheticMessagesFixture.numericReactionMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [112])
        XCTAssertEqual(messages.first?.text, "Reacted to a message")
    }

    func testFetchMessagesPreservesNormalPlusPrefixedText() throws {
        let service = DatabaseService()
        XCTAssertTrue(service.open(path: databaseURL.path))
        defer { service.close() }

        let messages = service.fetchMessages(
            chatID: 10,
            startDate: SyntheticMessagesFixture.normalPlusTextMessageDate,
            endDate: SyntheticMessagesFixture.normalPlusTextMessageDate.addingTimeInterval(1),
            keyword: nil,
            includeMedia: false
        )

        XCTAssertEqual(messages.map(\.messageID), [113])
        XCTAssertEqual(messages.first?.text, "+5")
    }
}

private enum SyntheticMessagesFixture {
    static let firstMessageDate = Date(timeIntervalSinceReferenceDate: 1_000)
    static let middleMessageDate = Date(timeIntervalSinceReferenceDate: 2_000)
    static let attachmentMessageDate = Date(timeIntervalSinceReferenceDate: 3_000)
    static let binaryBlobMessageDate = Date(timeIntervalSinceReferenceDate: 4_000)
    static let metadataBlobMessageDate = Date(timeIntervalSinceReferenceDate: 5_000)
    static let tapbackMessageDate = Date(timeIntervalSinceReferenceDate: 6_000)
    static let emojiMessageDate = Date(timeIntervalSinceReferenceDate: 7_000)
    static let rawTapbackMessageDate = Date(timeIntervalSinceReferenceDate: 8_000)
    static let typedstreamMessageDate = Date(timeIntervalSinceReferenceDate: 9_000)
    static let customReactionMessageDate = Date(timeIntervalSinceReferenceDate: 10_000)
    static let numericReactionMessageDate = Date(timeIntervalSinceReferenceDate: 11_000)
    static let normalPlusTextMessageDate = Date(timeIntervalSinceReferenceDate: 12_000)

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
                attributedBody BLOB,
                associated_message_type INTEGER,
                associated_message_guid TEXT
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
        try insertMessage(db, id: 103, text: "", date: attachmentMessageDate.addingTimeInterval(60), isFromMe: false, handleID: 1, attributedBodyText: "Hidden settlement phrase")
        try insertMessage(db, id: 104, text: "Completely different", date: attachmentMessageDate.addingTimeInterval(120), isFromMe: false, handleID: 1, attributedBodyText: "Archived note body")
        try insertMessage(db, id: 105, text: "", date: binaryBlobMessageDate, isFromMe: false, handleID: 1, attributedBodyHex: "533093306b3061306f30")
        try insertMessage(db, id: 106, text: "", date: metadataBlobMessageDate, isFromMe: false, handleID: 1, attributedBodyText: "__kIMMessagePartAttributeName")
        try insertMessage(db, id: 107, text: "", date: tapbackMessageDate, isFromMe: false, handleID: 1, attributedBodyText: "+kLiked", associatedMessageType: 2001)
        try insertMessage(db, id: 108, text: "", date: emojiMessageDate, isFromMe: false, handleID: 1, attributedBodyText: "\u{1F44D}\u{1F44D}")
        try insertMessage(db, id: 109, text: "+kLiked", date: rawTapbackMessageDate, isFromMe: false, handleID: 1)
        try insertMessage(db, id: 110, text: "", date: typedstreamMessageDate, isFromMe: false, handleID: 1, attributedBodyText: "streamtyped")
        try insertMessage(db, id: 111, text: "+:Awesome!", date: customReactionMessageDate, isFromMe: false, handleID: 1, associatedMessageGUID: "synthetic-reaction-target")
        try insertMessage(db, id: 112, text: "+5", date: numericReactionMessageDate, isFromMe: false, handleID: 1, associatedMessageGUID: "synthetic-reaction-target")
        try insertMessage(db, id: 113, text: "+5", date: normalPlusTextMessageDate, isFromMe: false, handleID: 1)

        try execute(
            db,
            """
            INSERT INTO chat_message_join (chat_id, message_id)
            VALUES (10, 100), (10, 101), (10, 102), (10, 103), (10, 104), (10, 105), (10, 106), (10, 107), (10, 108), (10, 109), (10, 110), (10, 111), (10, 112), (10, 113);
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
                                      handleID: Int?,
                                      attributedBodyText: String? = nil,
                                      attributedBodyHex: String? = nil,
                                      associatedMessageType: Int = 0,
                                      associatedMessageGUID: String = "") throws {
        let handleValue = handleID.map(String.init) ?? "NULL"
        let nanoseconds = Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
        let attributedBodyValue: String
        if let attributedBodyHex {
            attributedBodyValue = "X'\(attributedBodyHex)'"
        } else {
            attributedBodyValue = attributedBodyText.map { "X'\(hexEncodedData(for: $0))'" } ?? "NULL"
        }
        try execute(
            db,
            """
            INSERT INTO message (ROWID, text, date, is_from_me, handle_id, attributedBody, associated_message_type, associated_message_guid)
            VALUES (\(id), '\(text.replacingOccurrences(of: "'", with: "''"))', \(nanoseconds), \(isFromMe ? 1 : 0), \(handleValue), \(attributedBodyValue), \(associatedMessageType), '\(associatedMessageGUID.replacingOccurrences(of: "'", with: "''"))');
            """
        )
    }

    private static func hexEncodedData(for string: String) -> String {
        string.data(using: .utf8, allowLossyConversion: false)?
            .map { String(format: "%02x", $0) }
            .joined() ?? ""
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
