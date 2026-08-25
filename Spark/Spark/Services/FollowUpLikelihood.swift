import Foundation

/// A local, deterministic assessment of whether the sender's latest run of
/// messages likely calls for a reply. It intentionally uses the same rules
/// regardless of who sent the messages, so Follow Up and Respond stay symmetric.
enum FollowUpLikelihood: Equatable {
    case likely(reason: String)
    case review

    var isLikely: Bool {
        if case .likely = self { return true }
        return false
    }

    var label: String {
        label(subject: nil)
    }

    func label(subject: String?) -> String {
        switch self {
        case .likely(let reason):
            let prefix = subject.map { "\($0) " } ?? ""
            return "Likely: \(prefix)\(reason)"
        case .review: return "Review"
        }
    }

    static func classify(messageText: String?) -> Self {
        let text = normalize(messageText)
        guard !text.isEmpty else { return .review }

        if text.contains("?") { return .likely(reason: "asked a question") }

        if text.hasPrefix("can you") || text.hasPrefix("could you") || text.hasPrefix("would you") || text.hasPrefix("will you") {
            return .likely(reason: "made a request")
        }
        if text.contains("please") || text.contains("let me know") || text.contains("lmk") || text.contains("send me") || text.contains("confirm") || text.contains("any update") {
            return .likely(reason: "made a request")
        }
        if ["send ", "call ", "reply ", "review ", "check ", "share ", "tell me", "keep me posted", "rsvp"].contains(where: text.hasPrefix) {
            return .likely(reason: "made a request")
        }
        if text.hasPrefix("any news") || text.hasPrefix("status update") || text.hasPrefix("following up") {
            return .likely(reason: "requested an update")
        }
        if text.hasPrefix("when ") || text.hasPrefix("what ") || text.hasPrefix("where ") || text.hasPrefix("which ") || text.hasPrefix("who ") || text.hasPrefix("how ") || text.hasPrefix("are you") || text.hasPrefix("is ") || text.hasPrefix("does ") || text.hasPrefix("do you") || text.hasPrefix("did you") || text.hasPrefix("have you") || text.hasPrefix("should we") || text.hasPrefix("thoughts") || text.hasPrefix("any thoughts") {
            return .likely(reason: "asked for a decision")
        }
        return .review
    }

    static func classify(messageTexts: [String?]) -> Self {
        for messageText in messageTexts {
            let likelihood = classify(messageText: messageText)
            if likelihood.isLikely { return likelihood }
        }
        return .review
    }

    private static func normalize(_ messageText: String?) -> String {
        (messageText ?? "")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
