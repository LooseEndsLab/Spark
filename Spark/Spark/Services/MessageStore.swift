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
}
enum MessageStoreError: LocalizedError { case databaseUnavailable(String), queryFailed(String)
    var errorDescription: String? { switch self { case .databaseUnavailable(let d): return "Unable to open the local Messages database: \(d)"; case .queryFailed(let d): return "Unable to read local Messages metadata: \(d)" } }
}

final class SQLiteMessageStore: MessageStore {
    private let databaseURL: URL
    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")) { self.databaseURL = databaseURL }
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
        )
        SELECT c.ROWID, c.chat_identifier, c.display_name, m.ROWID, m.date, m.is_from_me,
               EXISTS (
                   SELECT 1 FROM chat_handle_join ch
                   WHERE ch.chat_id = c.ROWID
                   GROUP BY ch.chat_id HAVING COUNT(*) > 1
               ),
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
            messages.append(ConversationMessage(chatID: sqlite3_column_int64(statement, 0), chatIdentifier: Self.text(statement, 1) ?? "Unknown conversation", displayName: Self.text(statement, 2), messageID: sqlite3_column_int64(statement, 3), date: Self.dateFromAppleNanoseconds(rawDate), isFromMe: sqlite3_column_int(statement, 5) != 0, isGroupChat: sqlite3_column_int(statement, 6) != 0, hasOppositeDirectionReactionAfterMessage: sqlite3_column_int(statement, 7) != 0, likelihood: .review))
        }
        return messages
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
