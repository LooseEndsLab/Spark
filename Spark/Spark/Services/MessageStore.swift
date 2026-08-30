import Foundation
import SQLite3

protocol MessageStore {
    /// Returns the latest non-reaction message in each chat. This head scan is
    /// deliberately metadata-only; callers decide which conversations may read
    /// their transient message bodies.
    func latestConversationMessages() throws -> [ConversationMessage]
    /// Classifies only the final uninterrupted non-reaction run from the same
    /// sender as `conversation`'s latest message.
    func likelihoodForTrailingRun(in conversation: ConversationMessage) throws -> FollowUpLikelihood
    /// Reads transient identifying metadata only for group chats that have
    /// already passed the follow-up eligibility filters.
    func groupMetadata(for chatIDs: [Int64]) throws -> [Int64: GroupConversationMetadata]
}

struct GroupConversationMetadata: Equatable {
    var participantIdentifiers: [String] = []
    var photoData: Data?
}

extension MessageStore {
    func groupMetadata(for chatIDs: [Int64]) throws -> [Int64: GroupConversationMetadata] { [:] }
}
enum MessageStoreError: LocalizedError { case databaseUnavailable(String), queryFailed(String)
    var errorDescription: String? { switch self { case .databaseUnavailable(let d): return "Unable to open the local Messages database: \(d)"; case .queryFailed(let d): return "Unable to read local Messages metadata: \(d)" } }
}

final class SQLiteMessageStore: MessageStore {
    private let databaseURL: URL
    private let attachmentsDirectory: URL
    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db"),
        attachmentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/Attachments", directoryHint: .isDirectory)
    ) {
        self.databaseURL = databaseURL
        self.attachmentsDirectory = attachmentsDirectory
    }
    func latestConversationMessages() throws -> [ConversationMessage] {
        var database: OpaquePointer?
        let uri = "file:\(databaseURL.path(percentEncoded: false))?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }; throw MessageStoreError.databaseUnavailable(database.map { String(cString: sqlite3_errmsg($0)) } ?? "database could not be opened")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }

        let sql = """
        WITH latest_message_per_chat AS (
            SELECT
                cmj.chat_id,
                cmj.message_id,
                ROW_NUMBER() OVER (
                    PARTITION BY cmj.chat_id
                    ORDER BY m.date DESC, m.ROWID DESC
                ) AS position
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE COALESCE(m.associated_message_type, 0) = 0
        ),
        participant_counts AS (
            SELECT chat_id, COUNT(*) + 1 AS participant_count
            FROM chat_handle_join
            GROUP BY chat_id
        )
        SELECT c.ROWID, c.chat_identifier, c.display_name, m.ROWID, m.date, m.is_from_me,
               COALESCE(participant_counts.participant_count, 1) > 2,
               COALESCE(participant_counts.participant_count, 1),
               EXISTS (
                   SELECT 1
                   FROM chat_message_join reaction_join
                   JOIN message reaction ON reaction.ROWID = reaction_join.message_id
                   WHERE reaction_join.chat_id = c.ROWID
                     AND COALESCE(reaction.associated_message_type, 0) != 0
                     AND reaction.is_from_me != m.is_from_me
                     AND (reaction.date > m.date OR (reaction.date = m.date AND reaction.ROWID > m.ROWID))
               )
        FROM latest_message_per_chat latest
        JOIN chat c ON c.ROWID = latest.chat_id
        JOIN message m ON m.ROWID = latest.message_id
        LEFT JOIN participant_counts ON participant_counts.chat_id = c.ROWID
        WHERE latest.position = 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        var messages: [ConversationMessage] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
            let rawDate = sqlite3_column_int64(statement, 4)
            messages.append(ConversationMessage(chatID: sqlite3_column_int64(statement, 0), chatIdentifier: Self.text(statement, 1) ?? "Unknown conversation", displayName: Self.text(statement, 2), messageID: sqlite3_column_int64(statement, 3), date: Self.dateFromAppleNanoseconds(rawDate), isFromMe: sqlite3_column_int(statement, 5) != 0, isGroupChat: sqlite3_column_int(statement, 6) != 0, participantCount: Int(sqlite3_column_int(statement, 7)), hasOppositeDirectionReactionAfterMessage: sqlite3_column_int(statement, 8) != 0, likelihood: .review))
        }
        return messages
    }

    func groupMetadata(for chatIDs: [Int64]) throws -> [Int64: GroupConversationMetadata] {
        let uniqueChatIDs = Array(Set(chatIDs))
        guard !uniqueChatIDs.isEmpty else { return [:] }

        var database: OpaquePointer?
        let uri = "file:\(databaseURL.path(percentEncoded: false))?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw MessageStoreError.databaseUnavailable(database.map { String(cString: sqlite3_errmsg($0)) } ?? "database could not be opened")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }

        var metadata = Dictionary(uniqueKeysWithValues: uniqueChatIDs.map { ($0, GroupConversationMetadata()) })
        for ids in uniqueChatIDs.chunked(into: 200) {
            try loadParticipantIdentifiers(for: ids, into: &metadata, database: database)
            try loadGroupPhotos(for: ids, into: &metadata, database: database)
        }
        return metadata
    }

    func likelihoodForTrailingRun(in conversation: ConversationMessage) throws -> FollowUpLikelihood {
        var database: OpaquePointer?
        let uri = "file:\(databaseURL.path(percentEncoded: false))?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw MessageStoreError.databaseUnavailable(database.map { String(cString: sqlite3_errmsg($0)) } ?? "database could not be opened")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }

        let runSQL = """
        SELECT m.ROWID, m.is_from_me, COALESCE(m.associated_message_type, 0)
        FROM chat_message_join cmj
        JOIN message m ON m.ROWID = cmj.message_id
        WHERE cmj.chat_id = ?
        ORDER BY m.date DESC, m.ROWID DESC
        """
        var runStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, runSQL, -1, &runStatement, nil) == SQLITE_OK, let runStatement else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(runStatement) }
        guard sqlite3_bind_int64(runStatement, 1, conversation.chatID) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }

        var messageIDs: [Int64] = []
        while true {
            let result = sqlite3_step(runStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
            guard sqlite3_column_int64(runStatement, 2) == 0 else { continue }
            guard (sqlite3_column_int(runStatement, 1) != 0) == conversation.isFromMe else { break }
            messageIDs.append(sqlite3_column_int64(runStatement, 0))
        }
        return try likelihood(for: messageIDs, database: database)
    }

    private func likelihood(for messageIDs: [Int64], database: OpaquePointer) throws -> FollowUpLikelihood {
        // Bodies are fetched only for this already-eligible trailing run. Keep
        // each query bounded and let each decoded body go out of scope at once.
        for ids in messageIDs.chunked(into: 200) {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = "SELECT text, attributedBody FROM message WHERE ROWID IN (\(placeholders))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            for (offset, id) in ids.enumerated() {
                guard sqlite3_bind_int64(statement, Int32(offset + 1), id) == SQLITE_OK else {
                    throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
                }
            }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
                let text = MessageTextExtractor.text(plainText: Self.text(statement, 0), attributedBody: Self.data(statement, 1))
                let likelihood = FollowUpLikelihood.classify(messageText: text)
                if likelihood.isLikely { return likelihood }
            }
        }
        return .review
    }

    private func loadParticipantIdentifiers(for chatIDs: [Int64], into metadata: inout [Int64: GroupConversationMetadata], database: OpaquePointer) throws {
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let sql = """
        SELECT chat_handles.chat_id, participant.id
        FROM chat_handle_join chat_handles
        JOIN handle participant ON participant.ROWID = chat_handles.handle_id
        WHERE chat_handles.chat_id IN (\(placeholders))
        ORDER BY chat_handles.chat_id, participant.ROWID
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(chatIDs, to: statement, database: database)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
            let chatID = sqlite3_column_int64(statement, 0)
            guard let identifier = Self.text(statement, 1) else { continue }
            metadata[chatID, default: GroupConversationMetadata()].participantIdentifiers.append(identifier)
        }
    }

    private func loadGroupPhotos(for chatIDs: [Int64], into metadata: inout [Int64: GroupConversationMetadata], database: OpaquePointer) throws {
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let sql = """
        WITH ranked_photo_events AS (
            SELECT
                chat_messages.chat_id,
                group_event.ROWID AS message_id,
                ROW_NUMBER() OVER (
                    PARTITION BY chat_messages.chat_id
                    ORDER BY group_event.date DESC, group_event.ROWID DESC
                ) AS position
            FROM chat_message_join chat_messages
            JOIN message group_event ON group_event.ROWID = chat_messages.message_id
            WHERE chat_messages.chat_id IN (\(placeholders))
              AND group_event.item_type = 3
        )
        SELECT latest.chat_id, photo.filename
        FROM ranked_photo_events latest
        LEFT JOIN message_attachment_join photo_join ON photo_join.message_id = latest.message_id
        LEFT JOIN attachment photo ON photo.ROWID = photo_join.attachment_id
        WHERE latest.position = 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(chatIDs, to: statement, database: database)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
            let chatID = sqlite3_column_int64(statement, 0)
            guard metadata[chatID]?.photoData == nil,
                  let filename = Self.text(statement, 1),
                  let photoData = groupPhotoData(filename: filename)
            else { continue }
            metadata[chatID]?.photoData = photoData
        }
    }

    private static func bind(_ values: [Int64], to statement: OpaquePointer, database: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(offset + 1), value) == SQLITE_OK else {
                throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func groupPhotoData(filename: String) -> Data? {
        guard URL(fileURLWithPath: filename).lastPathComponent == "GroupPhotoImage" else { return nil }
        let expandedPath = NSString(string: filename).expandingTildeInPath
        let photoURL = URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath()
        let attachmentsURL = attachmentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard photoURL.path.hasPrefix(attachmentsURL.path + "/"),
              let fileSize = try? photoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= 25_000_000
        else { return nil }
        return try? Data(contentsOf: photoURL, options: .mappedIfSafe)
    }

    static func dateFromAppleNanoseconds(_ rawDate: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(rawDate) / 1_000_000_000)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? { guard let value = sqlite3_column_text(statement, column) else { return nil }; return String(cString: value) }
    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
