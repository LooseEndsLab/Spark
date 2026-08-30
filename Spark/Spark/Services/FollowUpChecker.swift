import Foundation

enum ConversationSelector {
    /// Mirrors MessageStore's SQL ranking: choose the latest message overall before
    /// considering whether it was sent by the local user.
    static func latestOverall(from messages: [ConversationMessage]) -> [ConversationMessage] {
        Dictionary(grouping: messages, by: \.chatID).values.compactMap { messages in
            messages.max { left, right in
                left.date == right.date ? left.messageID < right.messageID : left.date < right.date
            }
        }
    }
}

struct FollowUpChecker {
    let store: MessageStore

    func findFollowUps(thresholdDays: Int, maximumAgeDays: Int? = nil, ignoredChatIDs: Set<Int64>, dismissedMessageIDs: Set<Int64>, ignoreGroupChats: Bool, treatReactionsAsReplies: Bool = true, now: Date = .now) throws -> [FollowUp] {
        try findConversationStatuses(thresholdDays: thresholdDays, maximumAgeDays: maximumAgeDays, ignoredChatIDs: ignoredChatIDs, dismissedMessageIDs: dismissedMessageIDs, ignoreGroupChats: ignoreGroupChats, treatReactionsAsReplies: treatReactionsAsReplies, now: now).waitingOnThem
    }

    func findGhostedConversations(thresholdDays: Int, maximumAgeDays: Int? = nil, ignoredChatIDs: Set<Int64>, dismissedMessageIDs: Set<Int64>, ignoreGroupChats: Bool, treatReactionsAsReplies: Bool = true, now: Date = .now) throws -> [FollowUp] {
        try findConversationStatuses(thresholdDays: thresholdDays, maximumAgeDays: maximumAgeDays, ignoredChatIDs: ignoredChatIDs, dismissedMessageIDs: dismissedMessageIDs, ignoreGroupChats: ignoreGroupChats, treatReactionsAsReplies: treatReactionsAsReplies, now: now).waitingOnYou
    }

    func findConversationStatuses(thresholdDays: Int, maximumAgeDays: Int? = nil, ignoredChatIDs: Set<Int64>, dismissedMessageIDs: Set<Int64>, ignoreGroupChats: Bool, treatReactionsAsReplies: Bool = true, now: Date = .now) throws -> (waitingOnThem: [FollowUp], waitingOnYou: [FollowUp]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, thresholdDays), to: now) ?? now
        let maximumAgeCutoff = maximumAgeDays.flatMap { Calendar.current.date(byAdding: .day, value: -max(1, $0), to: now) }
        let metadataCandidates = try store.latestConversationMessages()
            .filter { $0.date <= cutoff }
            .filter { message in maximumAgeCutoff.map { message.date >= $0 } ?? true }
            .filter { !ignoreGroupChats || !$0.isGroupChat }
            .filter { !treatReactionsAsReplies || !$0.hasOppositeDirectionReactionAfterMessage }
            // Apply every eligibility check before message bodies are accessed.
            .filter { !ignoredChatIDs.contains($0.chatID) && !dismissedMessageIDs.contains($0.messageID) }
        let candidates = try metadataCandidates
            .map { candidate -> FollowUp in
                let likelihood = try store.likelihoodForTrailingRun(in: candidate)
                let classified = ConversationMessage(chatID: candidate.chatID, chatIdentifier: candidate.chatIdentifier, displayName: candidate.displayName, messageID: candidate.messageID, date: candidate.date, isFromMe: candidate.isFromMe, isGroupChat: candidate.isGroupChat, participantCount: candidate.participantCount, hasOppositeDirectionReactionAfterMessage: candidate.hasOppositeDirectionReactionAfterMessage, likelihood: likelihood)
                return FollowUp(conversation: classified)
            }
            .sorted { $0.conversation.date < $1.conversation.date }
        return (
            waitingOnThem: candidates.filter { $0.conversation.isFromMe },
            waitingOnYou: candidates.filter { !$0.conversation.isFromMe }
        )
    }
}
