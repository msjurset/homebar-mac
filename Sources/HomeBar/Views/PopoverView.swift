import SwiftUI
import AppKit

struct PopoverView: View {
    @Environment(HomeBarStore.self) private var store
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("homebar.gridMode") private var gridMode: Bool = false
    @AppStorage("homebar.showFrequent") private var showFrequent: Bool = false
    /// Our own estimate of what's at the top of the ScrollView viewport.
    /// Updated when we scroll programmatically (keyboard navigation). Not
    /// perfectly accurate if the user trackpad-scrolls manually, which is
    /// acceptable for a keyboard-driven popover.
    @State private var topVisibleID: String?

    private func openSettings() {
        AppController.shared.openSettings()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            Divider()
            footer
        }
        .frame(width: 360, height: 440)
        .task { await store.bootstrap() }
        .onAppear {
            focusSoon()
            refreshHotkeyMap()
        }
        .onChange(of: query) { _, _ in refreshDisplayed() }
        .onChange(of: store.pinnedIDs) { _, _ in refreshDisplayed() }
        .onChange(of: store.recents) { _, _ in refreshDisplayed() }
        .onChange(of: showFrequent) { _, _ in refreshDisplayed() }
        .onChange(of: gridMode) { _, _ in refreshDisplayed() }
        .onReceive(NotificationCenter.default.publisher(for: .homebarPanelDidOpen)) { _ in
            focusSoon()
            refreshHotkeyMap()
        }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill")
                .foregroundStyle(.tint)
            Text("HomeBar")
                .font(.headline)
            Spacer()
            Text(store.status.label)
                .font(.caption)
                .foregroundStyle(store.status == .connected ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !store.config.isConfigured ||
            (!store.config.usesOnePassword && Keychain.getToken() == nil) {
            notConfigured
        } else {
            connected
        }
    }

    private var notConfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Set your Home Assistant URL and token to get started.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            if query.isEmpty {
                defaultSections
            } else if filteredEntities.isEmpty {
                emptyResult
            } else {
                resultsList
            }
        }
    }

    @ViewBuilder
    private var defaultSections: some View {
        let pinned = store.pinnedEntities
        let recency = showFrequent ? store.frequentEntities : store.recentEntities
        if pinned.isEmpty && recency.isEmpty {
            emptyResult
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty {
                            sectionHeader(title: "FAVORITES", trailing: AnyView(viewModeToggle))
                            if gridMode {
                                grid(entities: pinned)
                            } else {
                                list(entities: pinned)
                            }
                        }
                        if !recency.isEmpty {
                            sectionHeader(
                                title: showFrequent ? "FREQUENT" : "RECENT",
                                trailing: AnyView(recencyToggle)
                            )
                            list(entities: recency)
                        }
                    }
                }
                .onChange(of: store.selectedEntityID) { _, id in
                    scrollToSelected(id, proxy: proxy)
                }
            }
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: nil, trailing: AnyView(viewModeToggle))
            ScrollViewReader { proxy in
                ScrollView {
                    if gridMode {
                        grid(entities: filteredEntities)
                    } else {
                        list(entities: filteredEntities)
                    }
                }
                .onChange(of: store.selectedEntityID) { _, id in
                    scrollToSelected(id, proxy: proxy)
                }
            }
        }
    }

    private func visualRow(of idx: Int) -> Int {
        if idx < store.gridCount {
            return idx / 4
        }
        let gridRows = (store.gridCount + 3) / 4
        return gridRows + (idx - store.gridCount)
    }

    /// Estimated viewport capacity in "visual rows". List rows (~44pt) fit
    /// more per viewport than grid rows (~90pt), so adapt by whether the
    /// current section is list-only, grid-only, or mixed.
    private var viewportRows: Int {
        let count = store.displayedEntityIDs.count
        if store.gridCount == 0 { return 7 }            // list only
        if store.gridCount == count { return 3 }         // grid only
        return 4                                         // mixed — grid + list
    }

    /// Scrolls only when the selection is outside the currently-visible
    /// window. The selected item is then brought to the top of the viewport.
    private func scrollToSelected(_ id: String?, proxy: ScrollViewProxy) {
        guard let id,
              let selIdx = store.displayedEntityIDs.firstIndex(of: id) else { return }

        guard let topID = topVisibleID,
              let topIdx = store.displayedEntityIDs.firstIndex(of: topID) else {
            // Unknown top — assume we're at the start, only scroll if
            // selection is beyond the visible window from row 0.
            let selRow = visualRow(of: selIdx)
            if selRow < viewportRows {
                topVisibleID = store.displayedEntityIDs.first
                return
            }
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .top)
            }
            topVisibleID = id
            return
        }

        let selRow = visualRow(of: selIdx)
        let topRow = visualRow(of: topIdx)
        // In the visible window → no scroll.
        if selRow >= topRow && selRow < topRow + viewportRows {
            return
        }
        // Off-screen — bring selection to the top of the viewport.
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(id, anchor: .top)
        }
        topVisibleID = id
    }

    private func sectionHeader(title: String?, trailing: AnyView) -> some View {
        HStack {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search \(store.entities.count) entities…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var emptyResult: some View {
        VStack(spacing: 6) {
            Image(systemName: query.isEmpty ? "pin.slash" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty
                 ? "Type to search, then pin favorites for quick access."
                 : "No matches for \u{201C}\(query)\u{201D}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(entities: [HAEntity]) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(entities) { entity in
                EntityTile(
                    entity: entity,
                    displayName: store.displayName(for: entity),
                    areaName: entity.areaID.flatMap { store.areaName[$0] },
                    isPinned: store.isPinned(entity.entityID),
                    hasAlias: store.aliases[entity.entityID] != nil,
                    hotkey: hotkey(for: entity.entityID),
                    aggregate: store.automationAggregate(for: entity.entityID),
                    isWatched: store.isWatched(entity.entityID),
                    isSelected: store.selectedEntityID == entity.entityID,
                    isOptionHeld: store.optionHeld,
                    onTap: { Task { await store.fire(entity) } },
                    onTogglePin: { store.togglePin(entity) },
                    onRename: { store.setAlias($0, for: entity.entityID) },
                    onSetSliderValue: { v in Task { await store.setTileSliderValue(entity, value: v) } },
                    onToggleWatch: { store.toggleWatch(entity) },
                    onMediaAction: { action in Task { await store.runMediaAction(action, on: entity) } },
                    otherMediaPlayers: otherMediaPlayers(excluding: entity.entityID),
                    onMediaGroupJoin: { memberID in
                        Task { await store.joinMediaPlayer(leader: entity, memberID: memberID) }
                    },
                    onMediaGroupUnjoin: { memberID in
                        Task { await store.unjoinMediaPlayer(entityID: memberID) }
                    }
                )
                .id(entity.entityID)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func otherMediaPlayers(excluding entityID: String) -> [HAEntity] {
        store.entities.filter { $0.domain == "media_player" && $0.entityID != entityID }
    }

    private func grid(entities: [HAEntity]) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 5),
            GridItem(.flexible(), spacing: 5),
            GridItem(.flexible(), spacing: 5),
            GridItem(.flexible(), spacing: 5),
        ], spacing: 5) {
            ForEach(entities) { entity in
                EntityTileCompact(
                    entity: entity,
                    displayName: store.displayName(for: entity),
                    isPinned: store.isPinned(entity.entityID),
                    hasAlias: store.aliases[entity.entityID] != nil,
                    hotkey: hotkey(for: entity.entityID),
                    aggregate: store.automationAggregate(for: entity.entityID),
                    isWatched: store.isWatched(entity.entityID),
                    isSelected: store.selectedEntityID == entity.entityID,
                    isOptionHeld: store.optionHeld,
                    onTap: { Task { await store.fire(entity) } },
                    onTogglePin: { store.togglePin(entity) },
                    onRename: { store.setAlias($0, for: entity.entityID) },
                    onSetSliderValue: { v in Task { await store.setTileSliderValue(entity, value: v) } },
                    onToggleWatch: { store.toggleWatch(entity) },
                    onMediaAction: { action in Task { await store.runMediaAction(action, on: entity) } },
                    otherMediaPlayers: otherMediaPlayers(excluding: entity.entityID),
                    onMediaGroupJoin: { memberID in
                        Task { await store.joinMediaPlayer(leader: entity, memberID: memberID) }
                    },
                    onMediaGroupUnjoin: { memberID in
                        Task { await store.unjoinMediaPlayer(entityID: memberID) }
                    }
                )
                .id(entity.entityID)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var recencyToggle: some View {
        HStack(spacing: 2) {
            Button(action: { showFrequent = false }) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(showFrequent ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.75))
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(showFrequent ? Color.clear : Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Recent")

            Button(action: { showFrequent = true }) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 10))
                    .foregroundStyle(showFrequent ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.5))
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(showFrequent ? Color.white.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Frequent")
        }
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            Button(action: { gridMode = false }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10))
                    .foregroundStyle(gridMode ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.75))
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(gridMode ? Color.clear : Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("List view")

            Button(action: { gridMode = true }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10))
                    .foregroundStyle(gridMode ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.5))
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(gridMode ? Color.white.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Tile view")
        }
    }

    private var filteredEntities: [HAEntity] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return store.entities.filter { e in
            e.friendlyName.lowercased().contains(q)
                || e.entityID.lowercased().contains(q)
                || (e.areaID.flatMap { store.areaName[$0] }?.lowercased().contains(q) ?? false)
        }
    }

    private var displayedEntities: [HAEntity] {
        if !query.isEmpty { return filteredEntities }
        let recency = showFrequent ? store.frequentEntities : store.recentEntities
        return store.pinnedEntities + recency
    }

    private func hotkey(for entityID: String) -> String? {
        guard let idx = displayedEntities.firstIndex(where: { $0.entityID == entityID }),
              idx < HomeBarStore.hotkeyCharacters.count else { return nil }
        return HomeBarStore.hotkeyCharacters[idx]
    }

    private func refreshHotkeyMap() {
        var map: [String: String] = [:]
        for (i, e) in displayedEntities.prefix(HomeBarStore.hotkeyCharacters.count).enumerated() {
            map[HomeBarStore.hotkeyCharacters[i]] = e.entityID
        }
        store.hotkeyMap = map
        store.setDisplayed(displayedEntities.map { $0.entityID }, gridCount: gridSectionCount)
    }

    /// Called whenever the displayed-entity list or its layout (grid vs list,
    /// pinned count, search filter, recency source) changes. Refreshes hotkey
    /// assignments + store.displayedEntityIDs + store.gridCount, and resets
    /// the scroll window so navigation starts from the top.
    private func refreshDisplayed() {
        refreshHotkeyMap()
        topVisibleID = store.displayedEntityIDs.first
    }

    /// Number of items at the head of `displayedEntities` that render as a
    /// grid. Favorites + filtered results render as grid when `gridMode` is on;
    /// the Recent/Frequent section is always list.
    private var gridSectionCount: Int {
        guard gridMode else { return 0 }
        if query.isEmpty {
            return store.pinnedEntities.count
        }
        return filteredEntities.count
    }

    private var footer: some View {
        HStack {
            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("HomeBar Settings")
            Spacer()
            Text("⌘/ to toggle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
