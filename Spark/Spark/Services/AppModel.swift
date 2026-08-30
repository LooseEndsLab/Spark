import Foundation
import Combine
@MainActor final class AppModel: ObservableObject {
    @Published private(set) var followUps: [FollowUp] = []; @Published private(set) var ghostedConversations: [FollowUp] = []; @Published private(set) var errorMessage: String?; @Published private(set) var isLoading = true
    @Published var thresholdDays: Int { didSet { if maximumConversationAgeDays < thresholdDays { maximumConversationAgeDays = thresholdDays }; defaults.set(max(1, thresholdDays), forKey: "thresholdDays"); refresh() } }
    @Published var maximumConversationAgeDays: Int { didSet { if maximumConversationAgeDays < thresholdDays { maximumConversationAgeDays = thresholdDays; return }; defaults.set(max(1, maximumConversationAgeDays), forKey: "maximumConversationAgeDays"); refresh() } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled"); if notificationsEnabled { Task { _ = await notifier.requestAuthorization(); await refreshNotifications() } } } }
    @Published var accentColor: AppAccent { didSet { defaults.set(accentColor.rawValue, forKey: "accentColor") } }
    @Published var onlyContacts: Bool { didSet { defaults.set(onlyContacts, forKey: "onlyContacts"); refresh() } }
    @Published var ignoreGroupChats: Bool { didSet { defaults.set(ignoreGroupChats, forKey: "ignoreGroupChats"); refresh() } }
    @Published var treatReactionsAsReplies: Bool { didSet { defaults.set(treatReactionsAsReplies, forKey: "treatReactionsAsReplies"); refresh() } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); do { try LaunchAtLoginManager.setEnabled(launchAtLogin) } catch { errorMessage = "Could not change Launch at Login: \(error.localizedDescription)" } } }
    private let store: MessageStore; private let notifier: NotificationManager; private let defaults: UserDefaults; private let contactsNameResolver = ContactsNameResolver()
    private let persistenceQueue = DispatchQueue(label: "com.looseends.spark.preferences", qos: .utility)
    private var ignoredChatIDs: Set<Int64>; private var dismissedFollowUpMessageIDs: Set<Int64>; private var dismissedResponseMessageIDs: Set<Int64>; private var notifiedMessageIDs: Set<Int64>
    private var refreshGeneration = 0
    @Published private(set) var contactNames: [String: String] = [:]
    init(store: MessageStore = SQLiteMessageStore(), notifier: NotificationManager = NotificationManager(), defaults: UserDefaults = .standard) {
        let initialThresholdDays = max(1, defaults.object(forKey: "thresholdDays") as? Int ?? 1)
        let initialMaximumConversationAgeDays = max(initialThresholdDays, defaults.object(forKey: "maximumConversationAgeDays") as? Int ?? 90)
        self.store = store; self.notifier = notifier; self.defaults = defaults; thresholdDays = initialThresholdDays; maximumConversationAgeDays = initialMaximumConversationAgeDays; notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? false; accentColor = AppAccent(rawValue: defaults.string(forKey: "accentColor") ?? "") ?? .warmAmber; onlyContacts = defaults.object(forKey: "onlyContacts") as? Bool ?? true; ignoreGroupChats = defaults.object(forKey: "ignoreGroupChats") as? Bool ?? true; treatReactionsAsReplies = defaults.object(forKey: "treatReactionsAsReplies") as? Bool ?? true; launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? LaunchAtLoginManager.isEnabled
        ignoredChatIDs = Set(defaults.array(forKey: "ignoredChatIDs") as? [Int64] ?? [])
        dismissedFollowUpMessageIDs = Set(defaults.array(forKey: "dismissedFollowUpMessageIDs") as? [Int64] ?? [])
        dismissedResponseMessageIDs = Set(defaults.array(forKey: "dismissedResponseMessageIDs") as? [Int64] ?? [])
        if dismissedFollowUpMessageIDs.isEmpty, dismissedResponseMessageIDs.isEmpty {
            let legacyDismissedMessageIDs = Set(defaults.array(forKey: "dismissedMessageIDs") as? [Int64] ?? [])
            dismissedFollowUpMessageIDs = legacyDismissedMessageIDs
            if !legacyDismissedMessageIDs.isEmpty {
                defaults.set(Array(dismissedFollowUpMessageIDs), forKey: "dismissedFollowUpMessageIDs")
                defaults.removeObject(forKey: "dismissedMessageIDs")
            }
        }
        notifiedMessageIDs = Set(defaults.array(forKey: "notifiedMessageIDs") as? [Int64] ?? [])
        refresh()
    }
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let store = store
        let thresholdDays = thresholdDays
        let maximumConversationAgeDays = maximumConversationAgeDays
        let ignoredChatIDs = ignoredChatIDs
        let dismissedMessageIDs = dismissedFollowUpMessageIDs.union(dismissedResponseMessageIDs)
        let ignoreGroupChats = ignoreGroupChats
        let treatReactionsAsReplies = treatReactionsAsReplies
        let onlyContacts = onlyContacts
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FollowUpChecker(store: store).findConversationStatuses(thresholdDays: thresholdDays, maximumAgeDays: maximumConversationAgeDays, ignoredChatIDs: ignoredChatIDs, dismissedMessageIDs: dismissedMessageIDs, ignoreGroupChats: ignoreGroupChats, treatReactionsAsReplies: treatReactionsAsReplies)
            }

            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                switch result {
                case .success(let statuses):
                    let allConversations = statuses.waitingOnThem + statuses.waitingOnYou
                    let contactNames = await contactsNameResolver.names(for: allConversations.map(\.conversation.chatIdentifier))
                    guard self.refreshGeneration == generation else { return }
                    self.contactNames = contactNames
                    followUps = onlyContacts ? statuses.waitingOnThem.filter { contactNames[$0.conversation.chatIdentifier] != nil } : statuses.waitingOnThem
                    ghostedConversations = onlyContacts ? statuses.waitingOnYou.filter { contactNames[$0.conversation.chatIdentifier] != nil } : statuses.waitingOnYou
                    errorMessage = nil
                    isLoading = false
                    await refreshNotifications()
                case .failure(let error):
                    followUps = []
                    ghostedConversations = []
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    func dismiss(_ item: FollowUp) {
        if item.conversation.isFromMe {
            guard dismissedFollowUpMessageIDs.insert(item.messageID).inserted else { return }
            removeFromVisibleConversations(messageID: item.messageID)
            saveDeferred(dismissedFollowUpMessageIDs, "dismissedFollowUpMessageIDs")
        } else {
            guard dismissedResponseMessageIDs.insert(item.messageID).inserted else { return }
            removeFromVisibleConversations(messageID: item.messageID)
            saveDeferred(dismissedResponseMessageIDs, "dismissedResponseMessageIDs")
        }
    }

    func resetDismissedFollowUps() {
        guard !dismissedFollowUpMessageIDs.isEmpty else { return }
        dismissedFollowUpMessageIDs.removeAll()
        save(dismissedFollowUpMessageIDs, "dismissedFollowUpMessageIDs")
        refresh()
    }

    func resetDismissedResponses() {
        guard !dismissedResponseMessageIDs.isEmpty else { return }
        dismissedResponseMessageIDs.removeAll()
        save(dismissedResponseMessageIDs, "dismissedResponseMessageIDs")
        refresh()
    }

    func ignore(_ item: FollowUp) {
        guard ignoredChatIDs.insert(item.chatID).inserted else { return }
        save(ignoredChatIDs, "ignoredChatIDs")
        removeFromVisibleConversations(chatID: item.chatID)
    }
    func openInMessages(_ item: FollowUp) { MessagesLauncher.open(chatIdentifier: item.conversation.chatIdentifier) }
    func name(for item: FollowUp) -> String { contactNames[item.conversation.chatIdentifier] ?? item.name }
    func unignore(_ id: Int64) { ignoredChatIDs.remove(id); save(ignoredChatIDs, "ignoredChatIDs"); refresh() }
    var ignoredChats: [Int64] { ignoredChatIDs.sorted() }
    var hasDismissedFollowUps: Bool { !dismissedFollowUpMessageIDs.isEmpty }
    var hasDismissedResponses: Bool { !dismissedResponseMessageIDs.isEmpty }
    private func removeFromVisibleConversations(messageID: Int64) {
        refreshGeneration += 1 // Prevent an in-flight database scan from restoring the row.
        followUps.removeAll { $0.messageID == messageID }
        ghostedConversations.removeAll { $0.messageID == messageID }
    }
    private func removeFromVisibleConversations(chatID: Int64) {
        refreshGeneration += 1 // Prevent an in-flight database scan from restoring the row.
        followUps.removeAll { $0.chatID == chatID }
        ghostedConversations.removeAll { $0.chatID == chatID }
    }
    private func refreshNotifications() async { guard notificationsEnabled else { return }; for item in followUps where NotificationDeduplicator.shouldNotify(messageID: item.messageID, notifiedMessageIDs: notifiedMessageIDs) { if await notifier.notifyIfPermitted(for: item) { notifiedMessageIDs.insert(item.messageID); save(notifiedMessageIDs, "notifiedMessageIDs") } } }
    private func save(_ values: Set<Int64>, _ key: String) { defaults.set(Array(values), forKey: key) }
    private func saveDeferred(_ values: Set<Int64>, _ key: String) {
        let values = Array(values)
        persistenceQueue.async { [defaults] in
            defaults.set(values, forKey: key)
        }
    }
}
