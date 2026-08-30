import Contacts
import Foundation

struct ContactNameIndex {
    private var namesByPhoneKey: [String: String] = [:]
    private var namesByEmail: [String: String] = [:]
    private var avatarsByPhoneKey: [String: Data] = [:]
    private var avatarsByEmail: [String: Data] = [:]

    mutating func add(name: String, phoneNumbers: [String], emailAddresses: [String], thumbnailImageData: Data? = nil) {
        guard !name.isEmpty else { return }
        for phoneNumber in phoneNumbers {
            for key in Self.phoneKeys(for: phoneNumber) {
                namesByPhoneKey[key, default: name] = name
                if let thumbnailImageData { avatarsByPhoneKey[key, default: thumbnailImageData] = thumbnailImageData }
            }
        }
        for emailAddress in emailAddresses {
            let key = Self.emailKey(for: emailAddress)
            namesByEmail[key, default: name] = name
            if let thumbnailImageData { avatarsByEmail[key, default: thumbnailImageData] = thumbnailImageData }
        }
    }

    func name(for identifier: String) -> String? {
        if let name = namesByEmail[Self.emailKey(for: identifier)] { return name }
        return Self.phoneKeys(for: identifier).lazy.compactMap { namesByPhoneKey[$0] }.first
    }

    func avatarData(for identifier: String) -> Data? {
        if let avatar = avatarsByEmail[Self.emailKey(for: identifier)] { return avatar }
        return Self.phoneKeys(for: identifier).lazy.compactMap { avatarsByPhoneKey[$0] }.first
    }

    static func phoneKeys(for value: String) -> Set<String> {
        let digits = value.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(String.init).joined()
        guard !digits.isEmpty else { return [] }

        var keys = [digits]
        if digits.count == 10 { keys.append("1" + digits) }
        if digits.count == 11, digits.hasPrefix("1") { keys.append(String(digits.dropFirst())) }
        return Set(keys)
    }

    static func emailKey(for value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ResolvedContacts {
    let names: [String: String]
    let avatarData: [String: Data]
}

final class ContactsNameResolver {
    private let contactStore = CNContactStore()
    private let queue = DispatchQueue(label: "com.looseends.spark.contacts", qos: .utility)
    private var index = ContactNameIndex()
    private var hasLoadedContacts = false
    private var namesByIdentifier: [String: String] = [:]
    private var avatarDataByIdentifier: [String: Data] = [:]

    func contacts(for identifiers: [String]) async -> ResolvedContacts {
        await withCheckedContinuation { continuation in
            queue.async {
                self.resolveContacts(for: identifiers, continuation: continuation)
            }
        }
    }

    private func resolveContacts(for identifiers: [String], continuation: CheckedContinuation<ResolvedContacts, Never>) {
        let unresolved = Set(identifiers).subtracting(namesByIdentifier.keys)
        guard !unresolved.isEmpty else {
            continuation.resume(returning: resolvedContacts)
            return
        }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            loadContactsIfNeeded()
            cacheContacts(for: unresolved)
            continuation.resume(returning: resolvedContacts)
        case .notDetermined:
            contactStore.requestAccess(for: .contacts) { granted, _ in
                self.queue.async {
                    guard granted else {
                        continuation.resume(returning: self.resolvedContacts)
                        return
                    }
                    self.loadContactsIfNeeded()
                    self.cacheContacts(for: unresolved)
                    continuation.resume(returning: self.resolvedContacts)
                }
            }
        default:
            continuation.resume(returning: resolvedContacts)
        }
    }

    private var resolvedContacts: ResolvedContacts {
        ResolvedContacts(names: namesByIdentifier, avatarData: avatarDataByIdentifier)
    }

    private func cacheContacts(for identifiers: Set<String>) {
        for identifier in identifiers {
            if let name = index.name(for: identifier) {
                namesByIdentifier[identifier] = name
            }
            if let avatarData = index.avatarData(for: identifier) {
                avatarDataByIdentifier[identifier] = avatarData
            }
        }
    }

    private func loadContactsIfNeeded() {
        guard !hasLoadedContacts else { return }
        hasLoadedContacts = true

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? contactStore.enumerateContacts(with: request) { [weak self] contact, _ in
            guard let self else { return }
            let name = Self.displayName(for: contact)
            self.index.add(
                name: name,
                phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                emailAddresses: contact.emailAddresses.map { $0.value as String },
                thumbnailImageData: contact.thumbnailImageData
            )
        }
    }

    private static func displayName(for contact: CNContact) -> String {
        let fullName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return fullName.isEmpty ? contact.nickname : fullName
    }
}
