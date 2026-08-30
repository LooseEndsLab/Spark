import SwiftUI
import AppKit
struct FollowUpRow: View {
    @EnvironmentObject private var model: AppModel
    let followUp: FollowUp
    let statusText: String
    let likelihoodSubject: String?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.openInMessages(followUp)
            } label: {
                HStack {
                    contactAvatar
                    VStack(alignment: .leading) {
                        Text(model.name(for: followUp)).lineLimit(1)
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Dismiss") {
                model.dismiss(followUp)
            }
            .buttonStyle(.borderless)

            Menu {
                Button("Open in Messages") { model.openInMessages(followUp) }
                Button("Dismiss") { model.dismiss(followUp) }
                Button("Ignore Conversation", role: .destructive) { model.ignore(followUp) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 5)
    }

    private var detailText: String {
        let groupLabel = followUp.conversation.isGroupChat ? " · Group chat" : ""
        return "\(followUp.likelihood.label(subject: likelihoodSubject)) · \(followUp.daysOld())d \(statusText)\(groupLabel)"
    }

    @ViewBuilder private var contactAvatar: some View {
        if let data = model.avatarData(for: followUp), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Text(initials)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
        }
    }

    private var initials: String {
        let components = model.name(for: followUp).split(whereSeparator: { $0.isWhitespace })
        return String(components.prefix(2).compactMap(\.first))
    }
}
