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
        let groupLabel = model.groupDescription(for: followUp).map { " · \($0)" } ?? ""
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
        } else if followUp.conversation.isGroupChat {
            GroupParticipantAvatarStack(members: model.groupParticipantAvatars(for: followUp))
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

private struct GroupParticipantAvatarStack: View {
    let members: [GroupParticipantAvatar]

    private var visibleMembers: [GroupParticipantAvatar] { Array(members.prefix(3)) }

    var body: some View {
        if visibleMembers.isEmpty {
            Image(systemName: "person.3.fill")
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
        } else {
            ZStack {
                ForEach(Array(visibleMembers.enumerated()), id: \.element.id) { index, member in
                    memberAvatar(member)
                        .offset(x: avatarOffset(for: index), y: index == 1 ? -5 : 5)
                        .zIndex(Double(index))
                }
            }
            .frame(width: 40, height: 34)
            .accessibilityLabel("Group members")
        }
    }

    @ViewBuilder private func memberAvatar(_ member: GroupParticipantAvatar) -> some View {
        if let imageData = member.imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
        } else {
            Text(initials(for: member.name))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color(for: member.name), in: Circle())
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
        }
    }

    private func avatarOffset(for index: Int) -> CGFloat {
        switch visibleMembers.count {
        case 1: 0
        case 2: index == 0 ? -7 : 7
        default: CGFloat(index - 1) * 9
        }
    }

    private func initials(for name: String) -> String {
        String(name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first))
    }

    private func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo]
        let index = name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count
        return palette[index]
    }
}
