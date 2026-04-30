import SwiftUI
import AppKit

struct PopoverView: View {
    @Environment(HomeBarStore.self) private var store
    @State private var query: String = ""
    @State private var cursor: Int = 0
    @State private var pendingCursor: Int?
    @State private var wantsSearchFocus: Bool = false
    @AppStorage("homebar.gridMode") private var gridMode: Bool = false
    @AppStorage("homebar.showFrequent") private var showFrequent: Bool = false
    /// Our own estimate of what's at the top of the ScrollView viewport.
    /// Updated when we scroll programmatically (keyboard navigation). Not
    /// perfectly accurate if the user trackpad-scrolls manually, which is
    /// acceptable for a keyboard-driven popover.
    @State private var topVisibleID: String?
    @State private var statusCopied: Bool = false
    @State private var statusCopiedTask: Task<Void, Never>?

    /// Frozen list of suggestion strings for the current typing session. Tab /
    /// arrows cycle through this list without recomputing; typing resets it.
    @State private var suggestionItems: [String] = []
    /// UTF-16 range in `query` that the next suggestion pick will replace.
    /// Updated after each preview so successive Tabs replace the last preview.
    @State private var suggestionReplaceRange: NSRange = .init(location: 0, length: 0)
    @State private var suggestionAddTrailingSpace: Bool = false
    /// Index of the currently highlighted item in `suggestionItems`. Tab /
    /// Arrow advance this without touching the field text; Enter commits it.
    @State private var suggestionIndex: Int = 0
    /// Set during acceptCurrentSuggestion so the query/cursor onChange
    /// handlers skip their recompute — the programmatic mutation has its own
    /// follow-up recompute that knows whether to chain into values or keys.
    @State private var isProgrammaticEdit: Bool = false
    /// Entity_id of the tile a drag is currently hovering over. Drives the
    /// budge offset on adjacent tiles and the insertion line on the target.
    @State private var dragOverID: String?
    /// How many recents/frequents to render. The list grows in increments of
    /// 10 when the user scrolls to the bottom sentinel.
    @State private var recencyLimit: Int = HomeBarStore.initialRecencyDisplay
    /// True while the brief delay before bumping `recencyLimit` is in flight,
    /// so the spinner has a moment to be visible during the lazy load.
    @State private var isLoadingMoreRecency: Bool = false

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
            Task { await store.reconcileNow() }
        }
        .onChange(of: query) { _, _ in
            recencyLimit = HomeBarStore.initialRecencyDisplay
            refreshDisplayed()
        }
        .onChange(of: store.pinnedIDs) { _, _ in refreshDisplayed() }
        .onChange(of: store.recents) { _, _ in refreshDisplayed() }
        .onChange(of: showFrequent) { _, _ in
            recencyLimit = HomeBarStore.initialRecencyDisplay
            refreshDisplayed()
        }
        .onChange(of: gridMode) { _, _ in refreshDisplayed() }
        .onChange(of: recencyLimit) { _, _ in refreshDisplayed() }
        .onReceive(NotificationCenter.default.publisher(for: .homebarPanelDidOpen)) { _ in
            recencyLimit = HomeBarStore.initialRecencyDisplay
            focusSoon()
            refreshHotkeyMap()
            Task { await store.reconcileNow() }
        }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            wantsSearchFocus = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill")
                .foregroundStyle(.tint)
            Text("HomeBar")
                .font(.headline)
            Spacer()
            statusLabel
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        let labelText = statusCopied ? "Copied" : store.status.label
        if case .failed(let msg) = store.status {
            Button(action: { copyStatus(msg) }) {
                Text(labelText)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
                    .underline(true, pattern: .dot)
            }
            .buttonStyle(.plain)
            .help("Click to copy error")
        } else {
            Text(labelText)
                .font(.caption)
                .foregroundStyle(store.status == .connected ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
    }

    private func copyStatus(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        statusCopied = true
        statusCopiedTask?.cancel()
        statusCopiedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            statusCopied = false
        }
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
            ZStack(alignment: .topLeading) {
                Group {
                    if query.isEmpty {
                        defaultSections
                    } else if filteredEntities.isEmpty {
                        emptyResult
                    } else {
                        resultsList
                    }
                }
                if store.searchSuggestionsVisible {
                    suggestionsDropdown
                        .padding(.leading, 26)
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var defaultSections: some View {
        let pinned = store.pinnedEntities
        let recencyAll = showFrequent ? store.frequentEntities : store.recentEntities
        let recencyShown = Array(recencyAll.prefix(recencyLimit))
        if pinned.isEmpty && recencyAll.isEmpty {
            emptyResult
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty {
                            sectionHeader(title: "FAVORITES", trailing: AnyView(viewModeToggle))
                            if gridMode {
                                grid(entities: pinned, reorderable: true)
                            } else {
                                list(entities: pinned, reorderable: true)
                            }
                        }
                        if !recencyShown.isEmpty {
                            sectionHeader(
                                title: showFrequent ? "FREQUENT" : "RECENT",
                                trailing: AnyView(recencyToggle)
                            )
                            list(entities: recencyShown)
                            // Always render the sentinel so reaching the
                            // end-of-list flashes a spinner regardless of
                            // whether more items can be loaded — that's the
                            // visual confirmation the user expects.
                            lazyLoadSentinel
                        }
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // True only when the content is actually scrollable AND
                    // the user has scrolled close to the bottom edge.
                    let scrollable = geometry.contentSize.height > geometry.containerSize.height + 1
                    let bottomEdge = geometry.contentOffset.y + geometry.containerSize.height
                    return scrollable && bottomEdge >= geometry.contentSize.height - 40
                } action: { _, nearBottom in
                    if nearBottom { loadMoreRecency() }
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
            FilterField(
                text: $query,
                placeholder: "Search \(store.entities.count) entities…",
                font: .systemFont(ofSize: 12),
                pendingCursor: $pendingCursor,
                onCursorChange: { cursor = $0 },
                onKey: handleSearchKey,
                onSubmit: submitSearch,
                wantsFocus: wantsSearchFocus
            )
            .frame(height: 18)
            if !query.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onChange(of: query) { _, _ in
            store.searchFieldHasText = !query.isEmpty
            if isProgrammaticEdit { return }
            recomputeSuggestions()
        }
        .onChange(of: cursor) { _, _ in
            if isProgrammaticEdit { return }
            recomputeSuggestions()
        }
    }

    private var suggestionsDropdown: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestionItems.enumerated()), id: \.offset) { idx, item in
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(idx == suggestionIndex ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .id(idx)
                            .onTapGesture {
                                suggestionIndex = idx
                                acceptCurrentSuggestion()
                            }
                    }
                }
            }
            .onChange(of: suggestionIndex) { _, idx in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
        )
        .frame(width: 220)
        .frame(maxHeight: 220, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func clearSearch() {
        query = ""
        pendingCursor = 0
        dismissSuggestions()
    }

    private func recomputeSuggestions() {
        // Use the text OUTSIDE the current word to gather already-used tokens
        // so the word being edited doesn't hide its own suggestions.
        let ns = query as NSString
        let clampedCursor = max(0, min(cursor, ns.length))
        // Probe with the real domain/area context so value-completion paths
        // (`domain:`, `area:`) survive the engine's `guard !values.isEmpty`
        // check when partial is empty. Otherwise we'd dismiss before ever
        // computing real suggestions.
        let domains = store.entities.map { $0.domain }
        let areaNames = store.areas.map { $0.name }
        let ctxProbe = SearchSuggestion.Context(
            input: query,
            cursor: clampedCursor,
            domains: domains,
            areaNames: areaNames,
            alreadyUsedTokens: []
        )
        guard let probe = SearchSuggestion.compute(ctxProbe) else {
            dismissSuggestions()
            return
        }
        let wordRange = probe.replaceRange
        let before = ns.substring(to: wordRange.location) as String
        let after = ns.substring(from: wordRange.location + wordRange.length) as String
        let otherTokens = SearchQuery.parse(before + " " + after).tokens

        let ctx = SearchSuggestion.Context(
            input: query,
            cursor: clampedCursor,
            domains: domains,
            areaNames: areaNames,
            alreadyUsedTokens: otherTokens
        )
        guard let result = SearchSuggestion.compute(ctx), !result.suggestions.isEmpty else {
            dismissSuggestions()
            return
        }
        suggestionItems = result.suggestions
        suggestionReplaceRange = result.replaceRange
        suggestionAddTrailingSpace = result.addTrailingSpace
        suggestionIndex = 0
        store.searchSuggestionsVisible = true
    }

    private func dismissSuggestions() {
        suggestionItems = []
        suggestionIndex = 0
        store.searchSuggestionsVisible = false
    }

    private func handleSearchKey(_ key: FilterFieldKey) -> Bool {
        switch key {
        case .tab, .arrowDown, .ctrlJ:
            if !store.searchSuggestionsVisible {
                recomputeSuggestions()
                return true
            }
            // Single-item list on Tab: fill it in (no trailing space, no
            // dismiss) so the user can keep typing or commit with Enter.
            if suggestionItems.count == 1 {
                performTabAutocomplete()
                return true
            }
            advanceHighlight(by: 1)
            return true
        case .backTab, .arrowUp, .ctrlK:
            if !store.searchSuggestionsVisible {
                recomputeSuggestions()
                return true
            }
            if suggestionItems.count == 1 {
                performTabAutocomplete()
                return true
            }
            advanceHighlight(by: -1)
            return true
        case .enter:
            guard store.searchSuggestionsVisible, !suggestionItems.isEmpty else { return false }
            acceptCurrentSuggestion()
            return true
        case .escape:
            if store.searchSuggestionsVisible {
                dismissSuggestions()
                return true
            }
            if !query.isEmpty {
                clearSearch()
                return true
            }
            return false
        }
    }

    private func advanceHighlight(by delta: Int) {
        let count = suggestionItems.count
        guard count > 0 else { return }
        suggestionIndex = (suggestionIndex + delta + count) % count
    }

    /// Insert the single highlighted suggestion into the field *without*
    /// committing (no trailing space, no dismiss). Used when Tab lands on a
    /// 1-item list so the user can keep typing or press Enter to finalize.
    private func performTabAutocomplete() {
        let idx = max(0, suggestionIndex)
        guard idx < suggestionItems.count else { return }
        let rawSuggestion = suggestionItems[idx]
        let ns = query as NSString
        let loc = suggestionReplaceRange.location
        let len = suggestionReplaceRange.length
        guard loc + len <= ns.length else { return }
        let before = ns.substring(with: NSRange(location: 0, length: loc)) as String
        let after = ns.substring(with: NSRange(location: loc + len, length: ns.length - loc - len)) as String
        let newCursor = (before as NSString).length + (rawSuggestion as NSString).length
        isProgrammaticEdit = true
        query = before + rawSuggestion + after
        cursor = newCursor
        pendingCursor = newCursor
        DispatchQueue.main.async {
            isProgrammaticEdit = false
            // Reopen dropdown in its new phase (key → values, or the same
            // single value if nothing else matches).
            recomputeSuggestions()
        }
    }

    private func acceptCurrentSuggestion() {
        let idx = suggestionIndex >= 0 ? suggestionIndex : 0
        guard idx < suggestionItems.count else { return }
        let rawSuggestion = suggestionItems[idx]
        let suggestion = rawSuggestion + (suggestionAddTrailingSpace ? " " : "")
        let ns = query as NSString
        let loc = suggestionReplaceRange.location
        let len = suggestionReplaceRange.length
        guard loc + len <= ns.length else { return }
        let before = ns.substring(with: NSRange(location: 0, length: loc)) as String
        let after = ns.substring(with: NSRange(location: loc + len, length: ns.length - loc - len)) as String
        let newCursor = (before as NSString).length + (suggestion as NSString).length
        let wasKeyCompletion = !suggestionAddTrailingSpace && rawSuggestion.hasSuffix(":")
        isProgrammaticEdit = true
        query = before + suggestion + after
        cursor = newCursor
        pendingCursor = newCursor
        dismissSuggestions()
        DispatchQueue.main.async {
            isProgrammaticEdit = false
            // Accepting a key like "is:" is only halfway to a real filter;
            // immediately reopen the dropdown with value suggestions.
            if wasKeyCompletion { recomputeSuggestions() }
        }
    }

    private func submitSearch() {
        // Plain Enter with no suggestions falls through to the app-level nav
        // monitor which fires the selected tile. Nothing to do here.
    }

    /// Visual-only footer for the recents/frequents list — renders a
    /// spinner while a lazy load is in flight, otherwise stays invisible.
    /// The actual load trigger lives on the parent ScrollView's
    /// `onScrollGeometryChange` so it only fires from real user scrolling.
    private var lazyLoadSentinel: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .opacity(isLoadingMoreRecency ? 1 : 0)
            Spacer()
        }
        .frame(height: 24)
    }

    private func loadMoreRecency() {
        guard !isLoadingMoreRecency else { return }
        isLoadingMoreRecency = true
        let totalAvailable = (showFrequent ? store.frequentEntities : store.recentEntities).count
        Task { @MainActor in
            // Brief flash of the spinner whether or not there's more to load.
            // The user wants the visual confirmation either way; if we're at
            // the true end, the spinner just blinks and disappears.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if recencyLimit < totalAvailable {
                withAnimation(.easeOut(duration: 0.15)) {
                    recencyLimit += 10
                }
            }
            isLoadingMoreRecency = false
        }
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

    private func list(entities: [HAEntity], reorderable: Bool = false) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(entities) { entity in
                tileWithReorder(entity: entity, reorderable: reorderable, axis: .vertical) {
                EntityTile(
                    entity: entity,
                    displayName: store.displayName(for: entity),
                    areaName: store.resolvedAreaID(for: entity).flatMap { store.areaName[$0] },
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
                }
                .id(entity.entityID)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// Wraps a tile with drag-and-drop affordances when `reorderable` is true.
    /// The dragged payload is the entity_id; on drop we reorder the pinned
    /// list so the dragged tile takes the target's slot. No-op when not
    /// reorderable so the same renderer works for search/recents too.
    ///
    /// While a drag hovers a target, the target and the tile immediately
    /// before it (in `pinnedIDs`) budge apart by ~8pt and an accent-colored
    /// insertion line appears between them. `axis` chooses whether the budge
    /// is vertical (list mode) or horizontal (grid mode).
    ///
    /// Slidable tiles can't use whole-tile `.draggable` because their inner
    /// `DragGesture` consumes the drag. For those, the drag source is a
    /// small grip handle overlay; the rest of the tile keeps its slider.
    @ViewBuilder
    private func tileWithReorder<Content: View>(
        entity: HAEntity,
        reorderable: Bool,
        axis: Axis,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if reorderable {
            let isSlider = HomeBarStore.isSlidable(entity)
            content()
                .offset(reorderOffset(for: entity.entityID, axis: axis))
                .overlay(alignment: axis == .vertical ? .top : .leading) {
                    if dragOverID == entity.entityID {
                        insertionLine(axis: axis)
                    }
                }
                .overlay(alignment: .top) {
                    if isSlider {
                        reorderGripHandle(for: entity.entityID)
                            .offset(y: -2)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: dragOverID)
                .modifier(WholeTileDraggable(id: entity.entityID, enabled: !isSlider))
                .dropDestination(for: String.self) { items, _ in
                    defer { dragOverID = nil }
                    guard let sourceID = items.first else { return false }
                    store.movePinned(sourceID, before: entity.entityID)
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        dragOverID = entity.entityID
                    } else if dragOverID == entity.entityID {
                        dragOverID = nil
                    }
                }
        } else {
            content()
        }
    }

    /// Small visible grip the user drags to reorder slidable tiles. The slider
    /// gesture sits on the icon area below; the grip is the only `.draggable`
    /// source so the two never fight over the same drag.
    private func reorderGripHandle(for entityID: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.secondary.opacity(0.65))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .draggable(entityID)
            .onHover { inside in
                if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
            .help("Drag to reorder")
    }

    /// How much to nudge a tile when a drag is hovering over a neighbor. The
    /// drop target shifts forward (down/right) by half the gap; the tile
    /// immediately before it in the pinned order shifts backward by the
    /// other half. Together they open a visible gap centered on the
    /// insertion line.
    private func reorderOffset(for entityID: String, axis: Axis) -> CGSize {
        let half: CGFloat = 4
        guard let target = dragOverID else { return .zero }
        if entityID == target {
            return axis == .vertical
                ? CGSize(width: 0, height: half)
                : CGSize(width: half, height: 0)
        }
        guard let targetIdx = store.pinnedIDs.firstIndex(of: target),
              targetIdx > 0,
              store.pinnedIDs[targetIdx - 1] == entityID else { return .zero }
        return axis == .vertical
            ? CGSize(width: 0, height: -half)
            : CGSize(width: -half, height: 0)
    }

    @ViewBuilder
    private func insertionLine(axis: Axis) -> some View {
        switch axis {
        case .vertical:
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: -3)
        case .horizontal:
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 4)
                .offset(x: -3)
        }
    }

    private func otherMediaPlayers(excluding entityID: String) -> [HAEntity] {
        store.entities.filter { $0.domain == "media_player" && $0.entityID != entityID }
    }

    private func grid(entities: [HAEntity], reorderable: Bool = false) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 5),
            GridItem(.flexible(), spacing: 5),
            GridItem(.flexible(), spacing: 5),
            GridItem(.flexible(), spacing: 5),
        ], spacing: 5) {
            ForEach(entities) { entity in
                tileWithReorder(entity: entity, reorderable: reorderable, axis: .horizontal) {
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
                }
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parsed = SearchQuery.parse(query)
        guard !parsed.isEmpty else { return [] }
        let areaNameLookup: [String: String] = store.areaName
        return store.entities.filter { e in
            parsed.matches(
                e,
                areaName: { areaNameLookup[$0] },
                areaID: { store.resolvedAreaID(for: $0) },
                isWatched: { store.isWatched($0) }
            )
        }
    }

    private var displayedEntities: [HAEntity] {
        if !query.isEmpty { return filteredEntities }
        let recency = (showFrequent ? store.frequentEntities : store.recentEntities)
            .prefix(recencyLimit)
        return store.pinnedEntities + Array(recency)
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

/// Conditionally attaches `.draggable(id)` to the whole tile. Used for
/// non-slidable tiles where there's no inner DragGesture to fight; slidable
/// tiles instead expose a dedicated grip handle as their drag source.
///
/// We deliberately don't switch the cursor on hover here — the whole tile
/// is the drag surface, so a grab cursor everywhere would feel intrusive
/// and conflict with the click/tap behavior that's the primary action.
/// macOS shows its own drag-with-payload cursor once the drag actually
/// begins, which is enough feedback.
private struct WholeTileDraggable: ViewModifier {
    let id: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(id)
        } else {
            content
        }
    }
}
