import Foundation
import SQLite3

protocol MessageStore { func latestConversationMessages() throws -> [ConversationMessage] }
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
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        // The latest uninterrupted run of eligible messages is read only for local
        // follow-up likelihood classification. No text is persisted, logged, or sent off this Mac.
        let sql = """
        WITH non_reaction_messages AS (
            SELECT cmj.chat_id, m.ROWID AS message_id, m.date, m.is_from_me, m.text, m.attributedBody
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE COALESCE(m.associated_message_type, 0) = 0
        ), run_boundaries AS (
            SELECT
                *,
                CASE WHEN LAG(is_from_me) OVER (
                    PARTITION BY chat_id
                    ORDER BY date, message_id
                ) IS is_from_me THEN 0 ELSE 1 END AS starts_run
            FROM non_reaction_messages
        ), run_messages AS (
            SELECT
                *,
                SUM(starts_run) OVER (
                    PARTITION BY chat_id
                    ORDER BY date, message_id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS run_id
            FROM run_boundaries
        ), latest_message_per_chat AS (
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY chat_id
                    ORDER BY date DESC, message_id DESC
                ) AS position
            FROM run_messages
        )
        SELECT c.ROWID, c.chat_identifier, c.display_name, m.message_id, m.date, m.is_from_me,
               trailing.text, trailing.attributedBody,
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
                     AND (reaction.date > m.date OR (reaction.date = m.date AND reaction.ROWID > m.message_id))
               )
        FROM latest_message_per_chat latest
        JOIN chat c ON c.ROWID = latest.chat_id
        JOIN run_messages m ON m.message_id = latest.message_id
        JOIN run_messages trailing ON trailing.chat_id = m.chat_id
            AND trailing.run_id = m.run_id
        WHERE latest.position = 1
        ORDER BY c.ROWID, m.date, m.message_id, trailing.date, trailing.message_id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        struct ConversationDraft {
            let chatID: Int64; let chatIdentifier: String; let displayName: String?; let messageID: Int64
            let date: Date; let isFromMe: Bool; let isGroupChat: Bool; let hasOppositeDirectionReactionAfterMessage: Bool
            var messageTexts: [String?]
        }
        var drafts: [Int64: ConversationDraft] = [:]
        var messageIDs: [Int64] = []
        var stepResult: Int32
        repeat {
            stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else { break }
            let messageText = MessageTextExtractor.text(plainText: Self.text(statement, 6), attributedBody: Self.data(statement, 7))
            let messageID = sqlite3_column_int64(statement, 3)
            if var draft = drafts[messageID] {
                draft.messageTexts.append(messageText)
                drafts[messageID] = draft
            } else {
                messageIDs.append(messageID)
                drafts[messageID] = ConversationDraft(chatID: sqlite3_column_int64(statement, 0), chatIdentifier: Self.text(statement, 1) ?? "Unknown conversation", displayName: Self.text(statement, 2), messageID: messageID, date: Self.dateFromAppleNanoseconds(sqlite3_column_int64(statement, 4)), isFromMe: sqlite3_column_int(statement, 5) != 0, isGroupChat: sqlite3_column_int(statement, 8) != 0, hasOppositeDirectionReactionAfterMessage: sqlite3_column_int(statement, 9) != 0, messageTexts: [messageText])
            }
        } while true
        guard stepResult == SQLITE_DONE else { throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(database))) }
        return messageIDs.compactMap { messageID in
            guard let draft = drafts[messageID] else { return nil }
            return ConversationMessage(chatID: draft.chatID, chatIdentifier: draft.chatIdentifier, displayName: draft.displayName, messageID: draft.messageID, date: draft.date, isFromMe: draft.isFromMe, isGroupChat: draft.isGroupChat, hasOppositeDirectionReactionAfterMessage: draft.hasOppositeDirectionReactionAfterMessage, likelihood: FollowUpLikelihood.classify(messageTexts: draft.messageTexts))
        }
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
