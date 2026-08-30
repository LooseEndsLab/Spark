import Foundation

struct ConversationMessage: Identifiable, Equatable {
    let chatID: Int64; let chatIdentifier: String; let displayName: String?; let messageID: Int64
    let date: Date; let isFromMe: Bool; let isGroupChat: Bool; let hasOppositeDirectionReactionAfterMessage: Bool; let likelihood: FollowUpLikelihood
    var id: Int64 { messageID }
}

struct FollowUp: Identifiable, Equatable {
    let conversation: ConversationMessage
    var id: Int64 { conversation.messageID }; var chatID: Int64 { conversation.chatID }; var messageID: Int64 { conversation.messageID }
    var name: String {
        if let displayName = conversation.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        return conversation.isGroupChat ? "Group Chat" : conversation.chatIdentifier
    }
    var likelihood: FollowUpLikelihood { conversation.likelihood }
    func daysOld(now: Date = .now) -> Int { max(0, Calendar.current.dateComponents([.day], from: conversation.date, to: now).day ?? 0) }
}
