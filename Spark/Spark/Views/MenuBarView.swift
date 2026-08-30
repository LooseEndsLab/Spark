import SwiftUI

struct MenuBarView: View {
    private enum ConversationTab: String, CaseIterable, Identifiable {
        case waitingOnThem = "Follow Up"
        case waitingOnYou = "Respond"

        var id: Self { self }
    }

    private enum LikelihoodFilter: String, CaseIterable, Identifiable {
        case likely = "Suggested"
        case all = "All"

        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab = ConversationTab.waitingOnThem
    @State private var likelihoodFilter = LikelihoodFilter.likely

    private var conversations: [FollowUp] {
        let items = selectedTab == .waitingOnThem ? model.followUps : model.ghostedConversations
        return likelihoodFilter == .likely ? items.filter { $0.likelihood.isLikely } : items
    }

    private var statusText: String {
        selectedTab == .waitingOnThem ? "waiting" : "awaiting your reply"
    }

    private var likelihoodSubject: String? {
        selectedTab == .waitingOnThem ? "you" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 12)
                Text("Spark")
                    .font(.headline)
                Spacer(minLength: 12)
                SlidingChoiceToggle(
                    selection: $selectedTab,
                    first: .waitingOnThem,
                    firstTitle: "Follow Up",
                    second: .waitingOnYou,
                    secondTitle: "Respond",
                    accentColor: model.accentColor.color,
                    accessibilityLabel: "Conversation type"
                )
                .frame(width: 132)

                Spacer(minLength: 12)
                Text("Show")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)
                SlidingChoiceToggle(
                    selection: $likelihoodFilter,
                    first: .likely,
                    firstTitle: "Suggested",
                    second: .all,
                    secondTitle: "All",
                    accentColor: model.accentColor.color,
                    accessibilityLabel: "Follow-up likelihood"
                )
                .frame(width: 136)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)

            Divider()

            content
                .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Settings") { openWindow(id: "settings") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding()
        }
        .frame(width: 460, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if let error = model.errorMessage {
            ScrollView { PermissionView(error: error) }
        } else if model.isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Checking conversations…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if conversations.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.secondary)
                Text(likelihoodFilter == .likely ? "No suggested follow-ups" : (selectedTab == .waitingOnThem ? "No follow-ups waiting" : "No responses due"))
                Text(likelihoodFilter == .likely ? "Use \"All\" to review every eligible conversation." : (selectedTab == .waitingOnThem ? "You’re all caught up." : "No one is waiting on your reply.")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { FollowUpRow(followUp: $0, statusText: statusText, likelihoodSubject: likelihoodSubject) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

}

private struct SlidingChoiceToggle<Value: Hashable>: View {
    @Binding var selection: Value
    let first: Value
    let firstTitle: String
    let second: Value
    let secondTitle: String
    let accentColor: Color
    let accessibilityLabel: String

    var body: some View {
        Button {
            selection = selection == first ? second : first
        } label: {
            GeometryReader { proxy in
                let isFirstSelected = selection == first

                ZStack(alignment: isFirstSelected ? .leading : .trailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                        }

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(accentColor)
                        .padding(2)
                        .frame(width: proxy.size.width / 2)
                        .shadow(color: .black.opacity(0.10), radius: 0.5, y: 0.5)
                        .animation(.easeInOut(duration: 0.18), value: isFirstSelected)

                    HStack(spacing: 0) {
                        choiceLabel(firstTitle, selected: isFirstSelected)
                        choiceLabel(secondTitle, selected: !isFirstSelected)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(height: 26)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selection == first ? firstTitle : secondTitle)
        .accessibilityHint("Click to switch to the other option")
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.12), value: selected)
    }
}
