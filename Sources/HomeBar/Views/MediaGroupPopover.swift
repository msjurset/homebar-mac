import SwiftUI

/// Long-press popover for a media_player tile. Shows the current group
/// members with remove buttons and other media_players available to add.
struct MediaGroupPopover: View {
    let leader: HAEntity
    let displayName: String
    let otherMediaPlayers: [HAEntity]
    let onJoin: (String) -> Void
    let onUnjoin: (String) -> Void

    private var memberIDs: [String] {
        HomeBarStore.mediaGroupMembers(leader)
            .filter { $0 != leader.entityID }
    }

    private var memberEntities: [HAEntity] {
        let byID = Dictionary(uniqueKeysWithValues: otherMediaPlayers.map { ($0.entityID, $0) })
        return memberIDs.compactMap { byID[$0] }
    }

    private var availableEntities: [HAEntity] {
        let memberSet = Set(memberIDs)
        return otherMediaPlayers.filter { !memberSet.contains($0.entityID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if HomeBarStore.mediaSupportsGrouping(leader) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !memberEntities.isEmpty {
                            sectionHeader("Members")
                            ForEach(memberEntities) { entity in
                                row(entity: entity, action: .remove)
                            }
                        } else {
                            Text("Not grouped with any other speaker.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !availableEntities.isEmpty {
                            sectionHeader("Add speaker")
                            ForEach(availableEntities) { entity in
                                row(entity: entity, action: .add)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                unsupportedMessage
            }
        }
        .frame(width: 280, height: 320)
    }

    private var unsupportedMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dynamic grouping not supported")
                .font(.system(size: 12, weight: .semibold))
            Text("Home Assistant can play to this speaker but doesn't expose the ability to add or remove group members. This is common for Google Cast groups — manage them in the Google Home app. Sonos and some other platforms support it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Group")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.headline)
                .lineLimit(1)
            Text(leader.entityID)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private enum RowAction { case add, remove }

    private func row(entity: HAEntity, action: RowAction) -> some View {
        Button {
            switch action {
            case .add: onJoin(entity.entityID)
            case .remove: onUnjoin(entity.entityID)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action == .add ? "plus.circle.fill" : "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(action == .add ? Color.accentColor : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.friendlyName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(entity.entityID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(entity.state)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
