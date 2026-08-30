import AppKit
import Foundation

enum MessagesLauncher {
    static func open(chatIdentifier: String, isGroupChat: Bool) {
        guard let url = url(for: chatIdentifier, isGroupChat: isGroupChat) else { return }
        NSWorkspace.shared.open(url)
    }

    static func url(for chatIdentifier: String, isGroupChat: Bool = false) -> URL? {
        let identifier = chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let permittedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+0123456789-.@_")
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy({ permittedCharacters.contains($0) }) else {
            return nil
        }

        if isGroupChat {
            var components = URLComponents()
            components.scheme = "sms"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "groupid", value: identifier)]
            return components.url
        }

        return URL(string: "sms:\(identifier)")
    }
}
