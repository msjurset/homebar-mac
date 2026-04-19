import SwiftUI

/// Per-automation "which entities count for tile aggregate" editor. Shows every
/// entity referenced in the automation's config; user checks the ones that
/// should drive the tile's color. Saving persists as a manual override; Reset
/// returns to the domain-based heuristic.
struct AutomationAffectsView: View {
    @Environment(HomeBarStore.self) private var store
    let automation: HAEntity
    let onClose: () -> Void

    @State private var selection: Set<String> = []

    private var affectedIDs: [String] {
        store.automationAffects[automation.entityID] ?? []
    }

    private var affectedEntities: [HAEntity] {
        let byID = Dictionary(uniqueKeysWithValues: store.entities.map { ($0.entityID, $0) })
        return affectedIDs
            .compactMap { byID[$0] }
            .sorted { $0.entityID < $1.entityID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            listContent
            Divider()
            footer
        }
        .frame(width: 460, height: 440)
        .onAppear { loadInitialSelection() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tile Entities")
                .font(.headline)
            Text(store.displayName(for: automation))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(automation.entityID)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var listContent: some View {
        if affectedEntities.isEmpty {
            VStack {
                Text("No entities detected in this automation's config.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(affectedEntities) { entity in
                        row(for: entity)
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(for entity: HAEntity) -> some View {
        let isSelected = selection.contains(entity.entityID)
        return Button {
            if isSelected { selection.remove(entity.entityID) }
            else { selection.insert(entity.entityID) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.friendlyName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(entity.entityID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(entity.domain) · \(entity.state)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button("Reset to Default") { resetToDefault() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { onClose() }
            Button("Save") {
                save()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func loadInitialSelection() {
        if let existing = store.automationOverrides[automation.entityID] {
            selection = Set(existing)
        } else {
            selection = Set(store.heuristicAggregateEntities(for: automation.entityID))
        }
    }

    private func resetToDefault() {
        store.setAutomationOverride(automation.entityID, selection: nil)
        selection = Set(store.heuristicAggregateEntities(for: automation.entityID))
    }

    private func save() {
        // Store the explicit selection. If it exactly matches the heuristic
        // default and there was no prior override, we could skip persisting,
        // but saving it explicitly makes the user's intent stable if the
        // heuristic changes later.
        store.setAutomationOverride(automation.entityID, selection: Array(selection))
    }
}
