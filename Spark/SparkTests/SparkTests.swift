//
//  SparkTests.swift
//  SparkTests
//
//  Created by Aryan Mehra on 8/20/26.
//

import Testing
import Foundation
import SQLite3
@testable import Spark

struct SparkTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func message(daysAgo: Int, fromMe: Bool = true, chatID: Int64 = 1, messageID: Int64 = 10, text: String? = nil, isGroup: Bool = false, hasReactionResponse: Bool = false) -> ConversationMessage { ConversationMessage(chatID: chatID, chatIdentifier: "test", displayName: "Test", messageID: messageID, date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!, isFromMe: fromMe, isGroupChat: isGroup, hasOppositeDirectionReactionAfterMessage: hasReactionResponse, likelihood: FollowUpLikelihood.classify(messageText: text)) }
    private func results(_ messages: [ConversationMessage], threshold: Int = 7, ignored: Set<Int64> = [], dismissed: Set<Int64> = []) throws -> [FollowUp] { try FollowUpChecker(store: StubStore(messages)).findFollowUps(thresholdDays: threshold, ignoredChatIDs: ignored, dismissedMessageIDs: dismissed, ignoreGroupChats: true, now: now) }
    private func ghostedResults(_ messages: [ConversationMessage], threshold: Int = 7, ignored: Set<Int64> = [], dismissed: Set<Int64> = []) throws -> [FollowUp] { try FollowUpChecker(store: StubStore(messages)).findGhostedConversations(thresholdDays: threshold, ignoredChatIDs: ignored, dismissedMessageIDs: dismissed, ignoreGroupChats: true, now: now) }
    @Test func outgoingOlderThanThresholdIsFollowUp() throws { #expect(try results([message(daysAgo: 7)]).count == 1) }
    @Test func newerOutgoingIsNotFollowUp() throws { #expect(try results([message(daysAgo: 6)]).isEmpty) }
    @Test func incomingLatestIsNotFollowUp() throws { #expect(try results([message(daysAgo: 20, fromMe: false)]).isEmpty) }
    @Test func oldIncomingMessageIsGhostedConversation() throws { #expect(try ghostedResults([message(daysAgo: 20, fromMe: false)]).count == 1) }
    @Test func oldOutgoingMessageIsNotGhostedConversation() throws { #expect(try ghostedResults([message(daysAgo: 20)]).isEmpty) }
    @Test func conversationOlderThanMaximumAgeIsIgnored() throws { #expect(try FollowUpChecker(store: StubStore([message(daysAgo: 91)])).findFollowUps(thresholdDays: 7, maximumAgeDays: 90, ignoredChatIDs: [], dismissedMessageIDs: [], ignoreGroupChats: true, now: now).isEmpty) }
    @Test func dismissedMessageIsNotFollowUp() throws { #expect(try results([message(daysAgo: 20)], dismissed: [10]).isEmpty) }
    @Test func ignoredConversationIsNotFollowUp() throws { #expect(try results([message(daysAgo: 20)], ignored: [1]).isEmpty) }
    @Test func notificationIsOnlyAllowedOncePerMessage() { #expect(NotificationDeduplicator.shouldNotify(messageID: 10, notifiedMessageIDs: [])); #expect(!NotificationDeduplicator.shouldNotify(messageID: 10, notifiedMessageIDs: [10])) }
    @Test func changingThresholdUpdatesResults() throws { #expect(try results([message(daysAgo: 8)], threshold: 7).count == 1); #expect(try results([message(daysAgo: 8)], threshold: 10).isEmpty) }
    @Test func appleNanosecondTimestampUsesAppleReferenceEpoch() {
        let date = SQLiteMessageStore.dateFromAppleNanoseconds(808_949_417_041_999_872)
        #expect(abs(date.timeIntervalSinceReferenceDate - 808_949_417.042) < 0.001)
    }
    @Test func oldOutgoingFollowedByIncomingReplyIsNotWaiting() throws {
        let conversation = ConversationSelector.latestOverall(from: [message(daysAgo: 20, fromMe: true, messageID: 1), message(daysAgo: 19, fromMe: false, messageID: 2)])
        #expect(try results(conversation).isEmpty)
    }
    @Test func multipleOutgoingMessagesWaitsFromNewestOutgoingMessage() throws {
        let conversation = ConversationSelector.latestOverall(from: [message(daysAgo: 20, messageID: 1), message(daysAgo: 8, messageID: 2)])
        let followUps = try results(conversation)
        #expect(followUps.count == 1)
        #expect(followUps.first?.messageID == 2)
    }
    @Test func incomingFollowedByNewerOutgoingMessageWaits() throws {
        let conversation = ConversationSelector.latestOverall(from: [message(daysAgo: 20, fromMe: false, messageID: 1), message(daysAgo: 8, fromMe: true, messageID: 2)])
        #expect(try results(conversation).count == 1)
    }
    @Test func oldConversationWithLatestIncomingMessageIsNotWaiting() throws {
        let conversation = ConversationSelector.latestOverall(from: [message(daysAgo: 400, fromMe: true, messageID: 1), message(daysAgo: 300, fromMe: false, messageID: 2)])
        #expect(try results(conversation).isEmpty)
    }

    @Test func oldOutgoingThenNewerIncomingIsNotWaitingInSQLiteStore() throws {
        let messages = try latestMessagesFromTestDatabase([
            (date: 10, isFromMe: true),
            (date: 20, isFromMe: false),
        ])

        #expect(messages.count == 1)
        #expect(messages[0].isFromMe == false)
        #expect(try results(messages).isEmpty)
    }

    @Test func incomingThenNewerOutgoingWaitsAfterThresholdInSQLiteStore() throws {
        let messages = try latestMessagesFromTestDatabase([
            (date: 10, isFromMe: false),
            (date: 20, isFromMe: true),
        ])

        #expect(messages.count == 1)
        #expect(messages[0].isFromMe == true)
        #expect(try results(messages, threshold: 7).count == 1)
    }

    @Test func multipleOutgoingMessagesUseNewestOutgoingInSQLiteStore() throws {
        let messages = try latestMessagesFromTestDatabase([
            (date: 10, isFromMe: true),
            (date: 20, isFromMe: true),
        ])

        #expect(messages.count == 1)
        #expect(messages[0].messageID == 2)
    }

    @Test func latestIncomingIsNotWaitingOnThemInSQLiteStore() throws {
        let messages = try latestMessagesFromTestDatabase([
            (date: 10, isFromMe: true),
            (date: 20, isFromMe: false),
        ])

        #expect(try results(messages).isEmpty)
    }

    @Test func outgoingReactionDoesNotMakeAnIncomingConversationWaitInSQLiteStore() throws {
        let messages = try latestMessagesFromTestDatabase([
            (date: 10, isFromMe: true, associatedMessageType: 0),
            (date: 20, isFromMe: false, associatedMessageType: 0),
            (date: 30, isFromMe: true, associatedMessageType: 2000),
        ])

        #expect(messages.count == 1)
        #expect(messages[0].isFromMe == false)
        #expect(try results(messages).isEmpty)
    }

    @Test func newerReactionFromTheOtherPersonIsRecordedAsAResponseInSQLiteStore() throws {
        let messages = try latestMessagesFromTestDatabase([
            (date: 10, isFromMe: true, associatedMessageType: 0),
            (date: 20, isFromMe: false, associatedMessageType: 2000),
        ])

        #expect(messages.count == 1)
        #expect(messages[0].isFromMe)
        #expect(messages[0].hasOppositeDirectionReactionAfterMessage)
    }

    @Test func messagesLauncherUsesThePhoneNumberAsTheRecipient() {
        #expect(MessagesLauncher.url(for: "+15555550123")?.absoluteString == "sms:+15555550123")
    }

    @Test func messagesLauncherRejectsNonRecipientChatIdentifiers() {
        #expect(MessagesLauncher.url(for: "iMessage;+;chat123") == nil)
    }

    @Test func contactNamesMatchEquivalentNorthAmericanPhoneFormats() {
        var index = ContactNameIndex()
        index.add(name: "Taylor", phoneNumbers: ["+1 (415) 555-1234"], emailAddresses: [])

        #expect(index.name(for: "4155551234") == "Taylor")
        #expect(index.name(for: "+14155551234") == "Taylor")
    }

    @Test func contactNamesMatchEmailIdentifiersCaseInsensitively() {
        var index = ContactNameIndex()
        index.add(name: "Riley", phoneNumbers: [], emailAddresses: ["Riley@Example.com"])

        #expect(index.name(for: "riley@example.com") == "Riley")
    }

    @Test func questionIsLikelyForEitherConversationDirection() {
        #expect(FollowUpLikelihood.classify(messageText: "Are you free Thursday?").isLikely)
        #expect(FollowUpLikelihood.classify(messageText: "Can you send the deck").isLikely)
    }

    @Test func directRequestsWithoutQuestionMarksAreLikely() {
        #expect(FollowUpLikelihood.classify(messageText: "Send the deck when you can").isLikely)
        #expect(FollowUpLikelihood.classify(messageText: "RSVP by Friday").isLikely)
        #expect(FollowUpLikelihood.classify(messageText: "Keep me posted on the outcome").isLikely)
    }

    @Test func decisionAndUpdatePromptsWithoutQuestionMarksAreLikely() {
        #expect(FollowUpLikelihood.classify(messageText: "Does Tuesday work for you").isLikely)
        #expect(FollowUpLikelihood.classify(messageText: "Thoughts on this approach").isLikely)
        #expect(FollowUpLikelihood.classify(messageText: "Any news on the application").isLikely)
    }

    @Test func genericStatementsRemainReview() {
        #expect(FollowUpLikelihood.classify(messageText: "The deck is ready").isReview)
        #expect(FollowUpLikelihood.classify(messageText: "Friday is busy for me").isReview)
    }

    @Test func acknowledgementIsKeptForReviewRatherThanLikely() {
        #expect(FollowUpLikelihood.classify(messageText: "Sounds good, thanks!") == .review)
        #expect(FollowUpLikelihood.classify(messageText: nil) == .review)
    }

    @Test func earlierQuestionInFinalSameSenderRunIsLikely() throws {
        let newest = message(daysAgo: 20, messageID: 2, text: "Sounds good")
        let store = RunSpyStore(messages: [newest], runs: [2: ["Can you send the deck?", "Sounds good"]])
        let followUps = try FollowUpChecker(store: store).findFollowUps(thresholdDays: 7, ignoredChatIDs: [], dismissedMessageIDs: [], ignoreGroupChats: true, now: now)
        #expect(followUps.first?.likelihood.isLikely == true)
        #expect(store.requestedMessageIDs == [2])
    }

    @Test func incomingMessageSplitsTrailingRun() throws {
        let newest = message(daysAgo: 20, messageID: 3)
        let store = RunSpyStore(messages: [newest], runs: [3: ["Sounds good"]])
        let followUps = try FollowUpChecker(store: store).findFollowUps(thresholdDays: 7, ignoredChatIDs: [], dismissedMessageIDs: [], ignoreGroupChats: true, now: now)
        #expect(followUps.first?.likelihood == .review)
    }

    @Test func ineligibleCandidatesNeverReadBodies() throws {
        let eligible = message(daysAgo: 20, chatID: 1, messageID: 1)
        let recent = message(daysAgo: 1, chatID: 2, messageID: 2)
        let ignored = message(daysAgo: 20, chatID: 3, messageID: 3)
        let dismissed = message(daysAgo: 20, chatID: 4, messageID: 4)
        let reacted = message(daysAgo: 20, chatID: 5, messageID: 5, hasReactionResponse: true)
        let tooOld = message(daysAgo: 100, chatID: 6, messageID: 6)
        let group = message(daysAgo: 20, chatID: 7, messageID: 7, isGroup: true)
        let store = RunSpyStore(messages: [eligible, recent, ignored, dismissed, reacted, tooOld, group], runs: [1: ["Can you help?"], 2: ["Can you help?"], 3: ["Can you help?"], 4: ["Can you help?"], 5: ["Can you help?"], 6: ["Can you help?"], 7: ["Can you help?"]])
        _ = try FollowUpChecker(store: store).findFollowUps(thresholdDays: 7, maximumAgeDays: 90, ignoredChatIDs: [3], dismissedMessageIDs: [4], ignoreGroupChats: true, now: now)
        #expect(store.requestedMessageIDs == [1])
    }

    @Test func SQLiteTrailingRunUsesEarlierQuestionButStopsAtIncomingMessage() throws {
        #expect(try trailingRunLikelihoodFromTestDatabase([
            (10, true, "Can you send the deck?"),
            (20, true, "Sounds good"),
        ]).isLikely)
        #expect(try trailingRunLikelihoodFromTestDatabase([
            (10, true, "Can you send the deck?"),
            (20, false, "I will reply later"),
            (30, true, "Sounds good"),
        ]) == .review)
    }

    @Test func likelihoodLabelCanNameTheSender() {
        #expect(FollowUpLikelihood.likely(reason: "asked a question").label(subject: "you") == "Likely: you asked a question")
        #expect(FollowUpLikelihood.review.label(subject: "you") == "Review")
    }

    @Test func reactionFromTheOtherPersonSuppressesWaitingByDefault() throws {
        #expect(try results([message(daysAgo: 20, hasReactionResponse: true)]).isEmpty)
        #expect(try FollowUpChecker(store: StubStore([message(daysAgo: 20, hasReactionResponse: true)])).findFollowUps(thresholdDays: 7, ignoredChatIDs: [], dismissedMessageIDs: [], ignoreGroupChats: true, treatReactionsAsReplies: false, now: now).count == 1)
    }

    @Test func reactionFromMeSuppressesGhostingByDefault() throws {
        #expect(try ghostedResults([message(daysAgo: 20, fromMe: false, hasReactionResponse: true)]).isEmpty)
    }

    @Test func attributedBodyTextIsUsedWhenPlainTextIsMissing() throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Can you send the deck?"), requiringSecureCoding: true)
        #expect(MessageTextExtractor.text(plainText: nil, attributedBody: archive) == "Can you send the deck?")
        #expect(FollowUpLikelihood.classify(messageText: MessageTextExtractor.text(plainText: nil, attributedBody: archive)).isLikely)
    }

    @Test func attributedBodyWithMessagesPrefixIsDecoded() throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Let me know your availability"), requiringSecureCoding: true)
        #expect(MessageTextExtractor.text(plainText: nil, attributedBody: Data([0x01, 0x02, 0x03]) + archive) == "Let me know your availability")
    }

    @Test func legacyAttributedBodyIsDecoded() throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "When can we reschedule our meeting?"), requiringSecureCoding: false)
        #expect(MessageTextExtractor.text(plainText: nil, attributedBody: archive) == "When can we reschedule our meeting?")
    }

    @Test func typedArchiveAttributedBodyIsDecoded() {
        let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Could I stop by when you are free?"))
        #expect(MessageTextExtractor.text(plainText: nil, attributedBody: archive) == "Could I stop by when you are free?")
        #expect(FollowUpLikelihood.classify(messageText: MessageTextExtractor.text(plainText: nil, attributedBody: archive)).isLikely)
    }

    @Test func plainTextTakesPrecedenceOverAttributedBody() throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "Can you send the deck?"), requiringSecureCoding: true)
        #expect(MessageTextExtractor.text(plainText: "Sounds good", attributedBody: archive) == "Sounds good")
    }

}

private extension FollowUpLikelihood {
    var isReview: Bool {
        if case .review = self { return true }
        return false
    }
}

private struct StubStore: MessageStore {
    let messages: [ConversationMessage]
    init(_ messages: [ConversationMessage]) { self.messages = messages }
    func latestConversationMessages() throws -> [ConversationMessage] { messages }
    func likelihoodForTrailingRun(in conversation: ConversationMessage) throws -> FollowUpLikelihood { conversation.likelihood }
}

private final class RunSpyStore: MessageStore {
    let messages: [ConversationMessage]
    let runs: [Int64: [String?]]
    private(set) var requestedMessageIDs: [Int64] = []
    init(messages: [ConversationMessage], runs: [Int64: [String?]]) { self.messages = messages; self.runs = runs }
    func latestConversationMessages() throws -> [ConversationMessage] { messages }
    func likelihoodForTrailingRun(in conversation: ConversationMessage) throws -> FollowUpLikelihood {
        requestedMessageIDs.append(conversation.messageID)
        return runs[conversation.messageID, default: []].map(FollowUpLikelihood.classify(messageText:)).first(where: \.isLikely) ?? .review
    }
}

private func latestMessagesFromTestDatabase(_ messages: [(date: Int64, isFromMe: Bool)]) throws -> [ConversationMessage] {
    try latestMessagesFromTestDatabase(messages.map { (date: $0.date, isFromMe: $0.isFromMe, associatedMessageType: 0) })
}

private func latestMessagesFromTestDatabase(_ messages: [(date: Int64, isFromMe: Bool, associatedMessageType: Int64)]) throws -> [ConversationMessage] {
    let databaseURL = FileManager.default.temporaryDirectory.appending(path: "SparkTests-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }

    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK, let database else {
        throw TestDatabaseError.couldNotOpen
    }
    defer { sqlite3_close(database) }

    try execute("CREATE TABLE chat (chat_identifier TEXT, display_name TEXT)", on: database)
    try execute("CREATE TABLE message (date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, associated_message_type INTEGER NOT NULL DEFAULT 0, text TEXT, attributedBody BLOB)", on: database)
    try execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)", on: database)
    try execute("CREATE TABLE chat_handle_join (chat_id INTEGER NOT NULL, handle_id INTEGER NOT NULL)", on: database)
    try execute("INSERT INTO chat (chat_identifier, display_name) VALUES ('test', 'Test')", on: database)
    for (index, message) in messages.enumerated() {
        try execute("INSERT INTO message (date, is_from_me, associated_message_type) VALUES (\(message.date), \(message.isFromMe ? 1 : 0), \(message.associatedMessageType))", on: database)
        try execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(index + 1))", on: database)
    }

    return try SQLiteMessageStore(databaseURL: databaseURL).latestConversationMessages()
}

private func trailingRunLikelihoodFromTestDatabase(_ messages: [(Int64, Bool, String)]) throws -> FollowUpLikelihood {
    let databaseURL = FileManager.default.temporaryDirectory.appending(path: "SparkTests-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK, let database else { throw TestDatabaseError.couldNotOpen }
    defer { sqlite3_close(database) }
    try execute("CREATE TABLE chat (chat_identifier TEXT, display_name TEXT)", on: database)
    try execute("CREATE TABLE message (date INTEGER NOT NULL, is_from_me INTEGER NOT NULL, associated_message_type INTEGER NOT NULL DEFAULT 0, text TEXT, attributedBody BLOB)", on: database)
    try execute("CREATE TABLE chat_message_join (chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL)", on: database)
    try execute("CREATE TABLE chat_handle_join (chat_id INTEGER NOT NULL, handle_id INTEGER NOT NULL)", on: database)
    try execute("INSERT INTO chat (chat_identifier, display_name) VALUES ('test', 'Test')", on: database)
    for (index, message) in messages.enumerated() {
        let escapedText = message.2.replacingOccurrences(of: "'", with: "''")
        try execute("INSERT INTO message (date, is_from_me, text) VALUES (\(message.0), \(message.1 ? 1 : 0), '\(escapedText)')", on: database)
        try execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(index + 1))", on: database)
    }
    let store = SQLiteMessageStore(databaseURL: databaseURL)
    guard let latest = try store.latestConversationMessages().first else { throw TestDatabaseError.queryFailed }
    return try store.likelihoodForTrailingRun(in: latest)
}

private func execute(_ sql: String, on database: OpaquePointer) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestDatabaseError.queryFailed
    }
}

private enum TestDatabaseError: Error { case couldNotOpen, queryFailed }
