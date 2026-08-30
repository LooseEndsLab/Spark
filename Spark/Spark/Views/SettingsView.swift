import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var isThresholdFieldFocused: Bool
    @FocusState private var isMaximumAgeFieldFocused: Bool
    @State private var thresholdDaysText = ""
    @State private var maximumAgeDaysText = ""

    var body: some View {
        Form {
            Section("Follow-up rules") {
                LabeledContent {
                    daysField(text: $thresholdDaysText, isFocused: $isThresholdFieldFocused, onSubmit: commitThresholdDays)
                } label: {
                    focusableSettingLabel("Follow up after") { isThresholdFieldFocused = true }
                }

                LabeledContent {
                    daysField(text: $maximumAgeDaysText, isFocused: $isMaximumAgeFieldFocused, onSubmit: commitMaximumAgeDays)
                } label: {
                    focusableSettingLabel("Ignore conversations older than") { isMaximumAgeFieldFocused = true }
                }

                Text("The follow-up delay can be 1–365 days. The maximum age must be at least as long as that delay, up to 3,650 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Conversation filters") {
                Toggle("Only show contacts", isOn: $model.onlyContacts)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                Toggle("Ignore group chats", isOn: $model.ignoreGroupChats)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                Toggle("Treat reactions as replies", isOn: $model.treatReactionsAsReplies)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                Text("When contacts-only is on, Spark shows conversations whose identifiers match an entry in your local Contacts database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App behavior") {
                Toggle("Notifications", isOn: $model.notificationsEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                Toggle("Launch at Login", isOn: $model.launchAtLogin)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))

                Picker("Accent color", selection: $model.accentColor) {
                    ForEach(AppAccent.allCases) { accent in
                        Text(accent.title).tag(accent)
                    }
                }
            }

            Section("Manage saved activity") {
                LabeledContent("Ignored conversations") {
                    Text("\(model.ignoredChats.count)")
                        .foregroundStyle(.secondary)
                }

                if model.ignoredChats.isEmpty {
                    Text("No conversations are currently ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.ignoredChats, id: \.self) { id in
                        LabeledContent("Chat \(id)") {
                            Button("Unignore") { model.unignore(id) }
                        }
                    }
                }

                Text("Restore items that still meet your current follow-up rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Dismissed follow-ups") {
                    Button("Restore") {
                        model.resetDismissedFollowUps()
                    }
                    .disabled(!model.hasDismissedFollowUps)
                }
                LabeledContent("Dismissed responses") {
                    Button("Restore") {
                        model.resetDismissedResponses()
                    }
                    .disabled(!model.hasDismissedResponses)
                }
            }

            Section {
                DisclosureGroup("How Spark decides what to suggest") {
                    likelihoodExplanation(
                        title: "1. Find the latest conversation message",
                        detail: "For each one-to-one chat, Spark finds the latest non-reaction message overall before checking who sent it. A newer normal reply means the chat is not pending."
                    )

                    likelihoodExplanation(
                        title: "2. Apply the response rule",
                        detail: "Your latest message appears in Follow Up; their latest message appears in Respond. When “Treat reactions as replies” is on, a newer reaction from the other person also counts as an acknowledgement."
                    )

                    likelihoodExplanation(
                        title: "3. Apply the age limits",
                        detail: "“Follow up after” is the minimum number of days since that latest message. “Ignore conversations older than” excludes chats beyond that maximum age."
                    )

                    likelihoodExplanation(
                        title: "4. Apply the exact local text checks",
                        detail: "The latest uninterrupted run of eligible messages from the same sender is read locally and transiently. Each text is lowercased and runs of whitespace are collapsed before these checks:\n• Contains “?” → asked a question.\n• Starts with “can you”, “could you”, “would you”, or “will you” → made a request.\n• Contains “please”, “let me know”, “lmk”, “send me”, “confirm”, or “any update” → made a request.\n• Starts with “send”, “call”, “reply”, “review”, “check”, “share”, “tell me”, “keep me posted”, or “RSVP” → made a request.\n• Starts with “any news”, “status update”, or “following up” → requested an update.\n• Starts with “when ”, “what ”, “where ”, “which ”, “who ”, “how ”, “are you”, “is ”, “does ”, “do you”, “did you”, “have you”, “should we”, “thoughts”, or “any thoughts” → asked for a decision."
                    )

                    likelihoodExplanation(
                        title: "5. Keep everything else available for review",
                        detail: "An empty message, or a message that matches none of those checks, is marked Review rather than Suggested. It remains in All if it passed the conversation, response, and age rules above. Message text is never saved or sent anywhere."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
        .onAppear(perform: syncDayFields)
        .onChange(of: isThresholdFieldFocused) { isFocused in
            if !isFocused { commitThresholdDays() }
        }
        .onChange(of: isMaximumAgeFieldFocused) { isFocused in
            if !isFocused { commitMaximumAgeDays() }
        }
        .onChange(of: model.thresholdDays) { _ in
            if !isThresholdFieldFocused { syncThresholdDaysText() }
        }
        .onChange(of: model.maximumConversationAgeDays) { _ in
            if !isMaximumAgeFieldFocused { syncMaximumAgeDaysText() }
        }
    }

    private func daysField(text: Binding<String>, isFocused: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField("", text: text)
                .labelsHidden()
                .frame(width: 54)
                .multilineTextAlignment(.trailing)
                .focused(isFocused)
                .onSubmit(onSubmit)
            Text("days")
                .foregroundStyle(.secondary)
        }
    }

    private func focusableSettingLabel(_ title: String, focus: @escaping () -> Void) -> some View {
        Button(action: focus) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func likelihoodExplanation(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func commitThresholdDays() {
        guard let days = Int(thresholdDaysText) else {
            syncThresholdDaysText()
            return
        }

        let thresholdDays = min(max(days, 1), 365)
        if thresholdDays != model.thresholdDays {
            model.thresholdDays = thresholdDays
        }
        syncDayFields()
    }

    private func commitMaximumAgeDays() {
        guard let days = Int(maximumAgeDaysText) else {
            syncMaximumAgeDaysText()
            return
        }

        let maximumAgeDays = min(max(days, model.thresholdDays), 3650)
        if maximumAgeDays != model.maximumConversationAgeDays {
            model.maximumConversationAgeDays = maximumAgeDays
        }
        syncMaximumAgeDaysText()
    }

    private func syncMaximumAgeDaysText() {
        maximumAgeDaysText = String(model.maximumConversationAgeDays)
    }

    private func syncThresholdDaysText() {
        thresholdDaysText = String(model.thresholdDays)
    }

    private func syncDayFields() {
        syncThresholdDaysText()
        syncMaximumAgeDaysText()
    }
}
