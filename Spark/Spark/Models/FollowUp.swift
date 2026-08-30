import Foundation

struct ConversationMessage: Identifiable, Equatable {
    let chatID: Int64; let chatIdentifier: String; let displayName: String?; let messageID: Int64
    let date: Date; let isFromMe: Bool; let isGroupChat: Bool; let participantCount: Int
    let participantIdentifiers: [String]
    let groupPhotoData: Data?
    let hasOppositeDirectionReactionAfterMessage: Bool; let likelihood: FollowUpLikelihood
    var id: Int64 { messageID }

    init(
        chatID: Int64,
        chatIdentifier: String,
        displayName: String?,
        messageID: Int64,
        date: Date,
        isFromMe: Bool,
        isGroupChat: Bool,
        participantCount: Int,
        participantIdentifiers: [String] = [],
        groupPhotoData: Data? = nil,
        hasOppositeDirectionReactionAfterMessage: Bool,
        likelihood: FollowUpLikelihood
    ) {
        self.chatID = chatID
        self.chatIdentifier = chatIdentifier
        self.displayName = displayName
        self.messageID = messageID
        self.date = date
        self.isFromMe = isFromMe
        self.isGroupChat = isGroupChat
        self.participantCount = participantCount
        self.participantIdentifiers = participantIdentifiers
        self.groupPhotoData = groupPhotoData
        self.hasOppositeDirectionReactionAfterMessage = hasOppositeDirectionReactionAfterMessage
        self.likelihood = likelihood
    }
}

enum GroupParticipantFormatter {
    static func names(for identifiers: [String], contactNames: [String: String]) -> [String] {
        identifiers.compactMap { contactNames[$0] }.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
    }

    static func summary(for identifiers: [String], contactNames: [String: String], maximumVisibleNames: Int = 3) -> String? {
        guard maximumVisibleNames > 0 else { return nil }
        let names = names(for: identifiers, contactNames: contactNames)
        guard !names.isEmpty else { return nil }

        let visibleNames = Array(names.prefix(maximumVisibleNames))
        let remainingCount = max(0, identifiers.count - visibleNames.count)
        let visibleSummary: String
        if visibleNames.count == 2, remainingCount == 0 {
            visibleSummary = visibleNames.joined(separator: " & ")
        } else {
            visibleSummary = visibleNames.joined(separator: ", ")
        }
        return remainingCount > 0 ? "\(visibleSummary) +\(remainingCount)" : visibleSummary
    }
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
    var groupDescription: String? {
        guard conversation.isGroupChat else { return nil }
        guard conversation.participantCount > 0 else { return "Group chat" }
        return "\(conversation.participantCount) \(conversation.participantCount == 1 ? "person" : "people")"
    }
    var likelihood: FollowUpLikelihood { conversation.likelihood }
    func daysOld(now: Date = .now) -> Int { max(0, Calendar.current.dateComponents([.day], from: conversation.date, to: now).day ?? 0) }
}
