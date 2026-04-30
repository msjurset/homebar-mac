import Foundation
import Observation
import AppKit

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

@Observable
@MainActor
final class HomeBarStore {
    private let persistence = Persistence.shared
    private let client = HAClient()

    var config: HAConfig = .empty
    var status: ConnectionStatus = .disconnected
    var entities: [HAEntity] = []
    var areas: [HAArea] = []
    /// Resolved entity_id → area_id mapping. Built from the HA entity
    /// registry and device registry, since `area_id` typically lives on the
    /// device (or the entity-registry override) rather than in the entity's
    /// state attributes. Populated on connect and refreshed by reconcile.
    var entityAreaIDs: [String: String] = [:]
    var pinnedIDs: [String] = []
    var aliases: [String: String] = [:]
    var recents: [String] = []
    var usageCounts: [String: Int] = [:]
    /// Maps a hotkey character (e.g. "1", "a") to an entity_id for the currently
    /// displayed tile set. Updated by PopoverView as search/favorites change.
    var hotkeyMap: [String: String] = [:]
    /// Ordered list of entity_ids currently shown in the popover. Drives
    /// arrow-key selection and the "fire selected on Enter" shortcut.
    var displayedEntityIDs: [String] = []
    /// Number of items at the head of `displayedEntityIDs` that render as a
    /// grid in the popover. The rest render as a single-column list (the
    /// Recent/Frequent section). Used to switch arrow-key stride between
    /// grid-row-steps and list-step-by-one at the section boundary.
    var gridCount: Int = 0
    /// The entity_id the user has keyboard-selected for the next Enter action.
    var selectedEntityID: String?
    /// True while the Option key is held, used by tiles to toggle an
    /// "expanded" presentation (e.g. media_player transport overlay).
    var optionHeld: Bool = false
    /// True while the search field's suggestions dropdown is visible. The
    /// global navigation monitor defers arrow/enter/escape to the field while
    /// this is set so the dropdown can own those keys.
    var searchSuggestionsVisible: Bool = false
    /// Mirror of whether the popover's search field has any text. Lets the
    /// global escape monitor defer to the search field's own clear-on-escape
    /// handler instead of closing the panel.
    var searchFieldHasText: Bool = false
    /// Maps automation entity_id (e.g. "automation.office_toggle") to the list
    /// of entities referenced in its config. Populated asynchronously after
    /// connect; used to render aggregate tile color for automations.
    var automationAffects: [String: [String]] = [:]
    /// Per-automation manual override: automation entity_id → explicit list
    /// of entity_ids to include in aggregate. Missing key = use heuristic.
    var automationOverrides: [String: [String]] = [:]

    private var hasLoaded = false
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var dropWatchTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private var wakeObserver: NSObjectProtocol?
    private var entityIndex: [String: Int] = [:]
    /// Cadence of the periodic reconcile that re-fetches `get_states` to catch
    /// silently-dead subscriptions (socket alive, but HA stopped delivering
    /// `state_changed` events on its side).
    nonisolated static let reconcileInterval: TimeInterval = 60
    /// Hard timeout for a single reconcile request. Prevents a wedged
    /// socket from leaving `reconcileInFlight` stuck and starving future
    /// reconciles.
    nonisolated static let reconcileTimeout: TimeInterval = 8

    /// Exponential-ish reconnect backoff in seconds. Capped by re-using the
    /// last value on further attempts.
    nonisolated static let reconnectDelays: [Double] = [1, 2, 5, 15, 30]

    nonisolated static func reconnectDelay(forAttempt attempt: Int) -> Double {
        let capped = max(0, min(attempt, reconnectDelays.count - 1))
        return reconnectDelays[capped]
    }

    var areaName: [String: String] {
        var m: [String: String] = [:]
        for a in areas { m[a.areaID] = a.name }
        return m
    }

    /// Resolves an entity's area_id, checking state attributes first (rare
    /// but authoritative when present) and falling back to the entity/device
    /// registry mapping.
    func resolvedAreaID(for entity: HAEntity) -> String? {
        if let direct = entity.areaID { return direct }
        return entityAreaIDs[entity.entityID]
    }

    func bootstrap() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        config = await persistence.loadConfig()
        pinnedIDs = await persistence.loadPins()
        aliases = await persistence.loadAliases()
        recents = await persistence.loadRecents()
        usageCounts = await persistence.loadUsageCounts()
        automationOverrides = await persistence.loadAutomationOverrides()
        if config.isConfigured, (config.usesOnePassword || Keychain.getToken() != nil) {
            await connect()
        }
    }

    func saveConfig(_ new: HAConfig) async {
        config = new
        try? await persistence.saveConfig(new)
    }

    func saveToken(_ token: String) {
        try? Keychain.setToken(token)
    }

    /// Attempts a connection without persisting state; surfaces a succinct result.
    /// If `tokenOrRef` starts with `op://`, the token is resolved through 1Password.
    func testConnection(baseURL: String, tokenOrRef: String) async -> Result<Int, Error> {
        let temp = HAConfig(baseURL: baseURL, watchEntities: [], tokenRef: nil)
        guard let wsURL = temp.websocketURL else {
            return .failure(HAClientError.invalidURL)
        }
        let resolvedToken: String
        if tokenOrRef.hasPrefix("op://") {
            do { resolvedToken = try await OnePassword.resolve(tokenOrRef) }
            catch { return .failure(error) }
        } else {
            resolvedToken = tokenOrRef
        }
        let probe = HAClient()
        do {
            try await probe.connect(websocketURL: wsURL, token: resolvedToken)
            let states = try await probe.getStates()
            await probe.disconnect()
            return .success(states.count)
        } catch {
            await probe.disconnect()
            return .failure(error)
        }
    }

    func connect() async {
        guard config.isConfigured, let wsURL = config.websocketURL else {
            status = .disconnected
            return
        }
        status = .connecting

        let token: String
        if let ref = config.tokenRef, !ref.isEmpty {
            do {
                token = try await OnePassword.resolve(ref)
            } catch {
                status = .failed("1Password: \(error.localizedDescription)")
                return
            }
        } else if let t = Keychain.getToken() {
            token = t
        } else {
            status = .disconnected
            return
        }

        do {
            try await client.connect(websocketURL: wsURL, token: token)
            let loaded = try await client.getStates()
            let loadedAreas = (try? await client.getAreas()) ?? []
            let loadedEntityAreas = await Self.loadEntityAreaMap(client: client)
            entities = loaded.sorted { $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending }
            rebuildEntityIndex()
            areas = loadedAreas
            entityAreaIDs = loadedEntityAreas
            status = .connected
            reconnectAttempt = 0
            try await client.subscribeStateChanges()
            try? await client.subscribePersistentNotifications()
            try? await client.subscribeHomebarSpeak()
            startEventLoop()
            startHeartbeat()
            startDropWatcher()
            startReconcileLoop()
            registerWakeObserver()
            Task { await refreshAutomationAffects() }
        } catch {
            status = .failed(error.localizedDescription)
            if Self.isRetriableConnectError(error) {
                scheduleReconnect()
            }
        }
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        dropWatchTask?.cancel()
        dropWatchTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        unregisterWakeObserver()
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        status = .disconnected
        reconnectAttempt = 0
    }

    /// Builds the entity_id → area_id map by combining the entity registry
    /// (which has entity-level area override and a device link) with the
    /// device registry (which has the device's area). Entity-level area
    /// wins; otherwise falls back to the device's area.
    private static func loadEntityAreaMap(client: HAClient) async -> [String: String] {
        async let entityRegTask: [HAClient.EntityRegistryEntry] = (try? await client.getEntityRegistry()) ?? []
        async let deviceMapTask: [String: String] = (try? await client.getDeviceAreaMap()) ?? [:]
        let entityReg = await entityRegTask
        let deviceMap = await deviceMapTask
        var resolved: [String: String] = [:]
        for entry in entityReg {
            if let aid = entry.areaID {
                resolved[entry.entityID] = aid
            } else if let did = entry.deviceID, let dAid = deviceMap[did] {
                resolved[entry.entityID] = dAid
            }
        }
        return resolved
    }

    // MARK: Reconnect / heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.status == .connected else { continue }
                do {
                    try await self.pingWithTimeout(seconds: 10)
                } catch {
                    await self.handleUnexpectedDisconnect()
                    return
                }
            }
        }
    }

    private func pingWithTimeout(seconds: Double) async throws {
        let client = self.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await client.ping() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw HAClientError.notConnected
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Runs `reconcileNow()` every `reconcileInterval` seconds while connected.
    /// Catches "alive socket, dead subscription" — HA can stop delivering
    /// `state_changed` events without breaking the WebSocket; the heartbeat
    /// ping still succeeds, but tiles drift stale. The reconcile re-fetches
    /// the full snapshot and applies it, and surfaces a wedged socket as a
    /// thrown error that triggers the existing reconnect path.
    private func startReconcileLoop() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = HomeBarStore.reconcileInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard self.status == .connected else { continue }
                await self.reconcileNow()
            }
        }
    }

    /// Fetches a fresh `get_states` snapshot and replaces the entity list.
    /// Triggers reconnect on failure. Safe to call from the UI (e.g.
    /// popover-open) — debounced internally so back-to-back calls don't
    /// double up.
    private var reconcileInFlight: Bool = false
    func reconcileNow() async {
        guard status == .connected, !reconcileInFlight else { return }
        reconcileInFlight = true
        defer { reconcileInFlight = false }
        do {
            let fresh = try await Self.runWithTimeout(seconds: Self.reconcileTimeout) { [client] in
                try await client.getStates()
            }
            entities = fresh.sorted {
                $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending
            }
            rebuildEntityIndex()
            // Refresh areas too. If `connect()` raced or the registry call
            // failed silently (try?), this is the recovery path — without
            // it, `area:` autocomplete stays empty until a full reconnect.
            if let freshAreas = try? await client.getAreas(), !freshAreas.isEmpty {
                areas = freshAreas
            }
            // Same idea for the entity-area resolver — refresh on every
            // reconcile so newly-assigned areas in HA become filterable
            // without forcing a reconnect here.
            let freshMap = await Self.loadEntityAreaMap(client: client)
            if !freshMap.isEmpty {
                entityAreaIDs = freshMap
            }
        } catch {
            await handleUnexpectedDisconnect()
        }
    }

    /// Schedules a one-shot reconcile shortly after a user-initiated action.
    /// Confirms state sync even when the `state_changed` event lags behind
    /// the call_service round trip.
    private func scheduleQuickReconcile() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            await self?.reconcileNow()
        }
    }

    /// Races `body` against a timer; throws `HAClientError.notConnected` if
    /// the body doesn't return within `seconds`. Used to keep a wedged
    /// socket from indefinitely blocking the reconcile in-flight flag.
    private static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw HAClientError.notConnected
            }
            guard let result = try await group.next() else {
                throw HAClientError.notConnected
            }
            group.cancelAll()
            return result
        }
    }

    private func startDropWatcher() {
        dropWatchTask?.cancel()
        let client = self.client
        dropWatchTask = Task { [weak self] in
            let stream = client.unexpectedDisconnectStream
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.handleUnexpectedDisconnect()
                return
            }
        }
    }

    private func handleUnexpectedDisconnect() async {
        heartbeatTask?.cancel(); heartbeatTask = nil
        dropWatchTask?.cancel(); dropWatchTask = nil
        reconcileTask?.cancel(); reconcileTask = nil
        eventTask?.cancel(); eventTask = nil
        await client.disconnect()
        status = .disconnected
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = Self.reconnectDelay(forAttempt: attempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.connect()
        }
    }

    nonisolated static func isRetriableConnectError(_ error: Error) -> Bool {
        if let ha = error as? HAClientError {
            switch ha {
            case .invalidURL, .authFailed:
                return false
            case .notConnected, .protocolError, .serverError:
                return true
            }
        }
        return true
    }

    private func registerWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onWake()
            }
        }
    }

    private func unregisterWakeObserver() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    private func onWake() {
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { [weak self] in
            guard let self else { return }
            if self.status == .connected {
                do {
                    try await self.pingWithTimeout(seconds: 5)
                } catch {
                    await self.handleUnexpectedDisconnect()
                }
            } else {
                await self.connect()
            }
        }
    }

    // MARK: Live state updates

    private func startEventLoop() {
        eventTask?.cancel()
        let client = self.client
        eventTask = Task { [weak self] in
            let stream = await client.eventStream
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handle(event: event)
            }
        }
    }

    private func handle(event: HAEvent) {
        switch event.eventType {
        case "state_changed":
            handleStateChange(event)
        case "persistent_notifications_updated":
            handleNotificationEvent(event)
        case "homebar_speak":
            handleSpeakEvent(event)
        default:
            break
        }
    }

    private func handleSpeakEvent(_ event: HAEvent) {
        guard case .object(let data) = event.raw["data"] else { return }

        // Target filter: missing target broadcasts to all instances. A string
        // or string-array targets specific instances by instance name.
        if !targetMatchesThisInstance(data["target"]) { return }

        var volume: Float = 1.0
        if case .number(let v) = data["volume"] { volume = Float(v) }
        if case .string(let media) = data["media_url"], !media.isEmpty,
           let url = URL(string: media) {
            MediaPlayerService.shared.play(url, volume: volume)
            return
        }
        guard case .string(let message) = data["message"], !message.isEmpty else { return }
        var rate: Float? = nil
        if case .number(let r) = data["rate"] { rate = Float(r) }
        var voiceID: String? = nil
        if case .string(let v) = data["voice"] { voiceID = v }
        MediaPlayerService.shared.speak(message, rate: rate, volume: volume, voiceID: voiceID)
    }

    private func targetMatchesThisInstance(_ target: HAValue?) -> Bool {
        guard let target else { return true }
        let me = config.effectiveInstanceName.lowercased()
        switch target {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t.isEmpty || t == me
        case .array(let arr):
            for v in arr {
                if case .string(let s) = v,
                   s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == me {
                    return true
                }
            }
            return false
        default:
            // Unknown shape — err on broadcasting to avoid silent drops.
            return true
        }
    }

    private func handleStateChange(_ event: HAEvent) {
        guard let change = event.stateChange,
              let updated = HAClient.parseEntity(from: change.newState) else { return }

        if let idx = entityIndex[change.entityID] {
            entities[idx] = updated
        } else {
            entities.append(updated)
            entityIndex[change.entityID] = entities.count - 1
        }
    }

    private func handleNotificationEvent(_ event: HAEvent) {
        guard case .object(let data) = event.raw["data"],
              case .string(let changeType) = data["type"] else { return }
        // Only notify on newly added persistent notifications. "current" fires
        // on subscribe with existing ones — skip to avoid banner spam on launch.
        guard changeType == "added" else { return }
        guard case .object(let notif) = data["notification"] else { return }
        guard case .string(let id) = notif["notification_id"] else { return }
        let title: String = {
            if case .string(let s) = notif["title"] { return s }
            return ""
        }()
        let message: String = {
            if case .string(let s) = notif["message"] { return s }
            return ""
        }()
        NotificationService.shared.show(notificationID: id, title: title, message: message)
    }

    /// Dismisses a persistent notification in HA. Called when the user taps
    /// the Dismiss action on the macOS banner.
    func dismissHANotification(_ notificationID: String) async {
        do {
            try await client.callService(
                domain: "persistent_notification",
                service: "dismiss",
                data: ["notification_id": notificationID]
            )
        } catch {
            status = .failed("Dismiss failed: \(error.localizedDescription)")
        }
    }

    private func rebuildEntityIndex() {
        var idx: [String: Int] = [:]
        for (i, e) in entities.enumerated() { idx[e.entityID] = i }
        entityIndex = idx
    }

    // MARK: Pins

    func isPinned(_ entityID: String) -> Bool {
        pinnedIDs.contains(entityID)
    }

    /// Reorders pinned entities by dropping `sourceID` onto `targetID`. The
    /// dragged item is placed at the target's slot; anything after it shifts
    /// down. No-op if either id isn't pinned or source == target. Persists.
    func movePinned(_ sourceID: String, before targetID: String) {
        guard sourceID != targetID,
              let sourceIdx = pinnedIDs.firstIndex(of: sourceID),
              let targetIdx = pinnedIDs.firstIndex(of: targetID) else { return }
        pinnedIDs.remove(at: sourceIdx)
        let insertIdx = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        pinnedIDs.insert(sourceID, at: insertIdx)
        let snapshot = pinnedIDs
        Task { try? await persistence.savePins(snapshot) }
    }

    func togglePin(_ entity: HAEntity) {
        if let idx = pinnedIDs.firstIndex(of: entity.entityID) {
            pinnedIDs.remove(at: idx)
        } else {
            pinnedIDs.append(entity.entityID)
        }
        let snapshot = pinnedIDs
        Task { try? await persistence.savePins(snapshot) }
    }

    var pinnedEntities: [HAEntity] {
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })
        return pinnedIDs.compactMap { byID[$0] }
    }

    // MARK: Usage tracking (recent / frequent)

    private static let recentCap = 30
    /// How many recents/frequents to surface initially. Callers can render
    /// more by slicing further — the store-side lists are uncapped.
    static let initialRecencyDisplay = 10

    func recordUsage(_ entityID: String) {
        // Any successful user-initiated action clears a lingering "Failed:"
        // status banner so it doesn't stick around indefinitely.
        if case .failed = status { status = .connected }
        recents.removeAll { $0 == entityID }
        recents.insert(entityID, at: 0)
        if recents.count > Self.recentCap {
            recents = Array(recents.prefix(Self.recentCap))
        }
        usageCounts[entityID, default: 0] += 1

        let r = recents
        let c = usageCounts
        Task {
            try? await persistence.saveRecents(r)
            try? await persistence.saveUsageCounts(c)
        }

        // The state_changed event from HA usually arrives milliseconds after
        // the call_service success, but if the subscription is sluggish or
        // half-dead, this safety-net reconcile catches the divergence
        // without waiting for the next periodic tick.
        scheduleQuickReconcile()
    }

    /// Non-pinned entities in order of recent use. Uncapped — the popover
    /// chooses how many to render.
    var recentEntities: [HAEntity] {
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })
        let pinnedSet = Set(pinnedIDs)
        return recents
            .compactMap { byID[$0] }
            .filter { !pinnedSet.contains($0.entityID) }
    }

    /// Non-pinned entities ordered by total fire count desc. Uncapped — the
    /// popover chooses how many to render.
    var frequentEntities: [HAEntity] {
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })
        let pinnedSet = Set(pinnedIDs)
        return usageCounts
            .sorted { $0.value > $1.value }
            .compactMap { byID[$0.key] }
            .filter { !pinnedSet.contains($0.entityID) }
    }

    // MARK: Aliases (local rename — not pushed to HA)

    func displayName(for entity: HAEntity) -> String {
        aliases[entity.entityID] ?? entity.friendlyName
    }

    func setAlias(_ alias: String?, for entityID: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            aliases[entityID] = trimmed
        } else {
            aliases.removeValue(forKey: entityID)
        }
        let snapshot = aliases
        Task { try? await persistence.saveAliases(snapshot) }
    }

    // MARK: Hotkeys

    static let hotkeyCharacters: [String] = {
        let digits = (1...9).map(String.init)
        let letters = (97...122).compactMap { UnicodeScalar($0) }.map { String(Character($0)) }
        return digits + letters
    }()

    func entity(forHotkey key: String) -> HAEntity? {
        let k = key.lowercased()
        guard let entityID = hotkeyMap[k] else { return nil }
        return entities.first(where: { $0.entityID == entityID })
    }

    // MARK: Keyboard navigation

    /// Refresh the displayed list. Keeps the current selection if still
    /// visible; otherwise clears it. Selection is intentionally NOT
    /// auto-applied — arrow keys start selection; until then no tile wears
    /// the selection outline.
    func setDisplayed(_ ids: [String], gridCount: Int = 0) {
        displayedEntityIDs = ids
        self.gridCount = max(0, min(gridCount, ids.count))
        if let sel = selectedEntityID, !ids.contains(sel) {
            selectedEntityID = nil
        }
    }

    /// Move selection down one row. In grid section strides by `columns`; in
    /// list section strides by 1. When the stride from the grid would land
    /// past the grid's last row, selection jumps to the first item of the
    /// list section (if there is one).
    func selectDown(columns: Int) {
        guard !displayedEntityIDs.isEmpty else { return }
        guard let current = selectedEntityID,
              let idx = displayedEntityIDs.firstIndex(of: current) else {
            selectedEntityID = displayedEntityIDs.first
            return
        }

        let target: Int
        if idx < gridCount {
            let gridTarget = idx + max(1, columns)
            if gridTarget < gridCount {
                target = gridTarget
            } else if gridCount < displayedEntityIDs.count {
                // Spill out of the grid into the first list item.
                target = gridCount
            } else {
                return
            }
        } else {
            target = idx + 1
            guard target < displayedEntityIDs.count else { return }
        }
        selectedEntityID = displayedEntityIDs[target]
    }

    func selectUp(columns: Int) {
        guard !displayedEntityIDs.isEmpty else { return }
        guard let current = selectedEntityID,
              let idx = displayedEntityIDs.firstIndex(of: current) else {
            selectedEntityID = displayedEntityIDs.last
            return
        }

        let target: Int
        if idx >= gridCount {
            let listTarget = idx - 1
            if listTarget >= gridCount {
                target = listTarget
            } else if gridCount > 0 {
                // Leaving the list — land on the last tile of the grid.
                target = gridCount - 1
            } else {
                return
            }
        } else {
            target = idx - max(1, columns)
            guard target >= 0 else { return }
        }
        selectedEntityID = displayedEntityIDs[target]
    }

    /// Move selection one column right. Only meaningful within the grid
    /// section; no-op when current selection is in the list section.
    func selectRight() {
        guard !displayedEntityIDs.isEmpty else { return }
        guard let current = selectedEntityID,
              let idx = displayedEntityIDs.firstIndex(of: current) else {
            selectedEntityID = displayedEntityIDs.first
            return
        }
        guard idx < gridCount else { return }
        let target = idx + 1
        if target < gridCount {
            selectedEntityID = displayedEntityIDs[target]
        }
    }

    func selectLeft() {
        guard !displayedEntityIDs.isEmpty else { return }
        guard let current = selectedEntityID,
              let idx = displayedEntityIDs.firstIndex(of: current) else {
            selectedEntityID = displayedEntityIDs.last
            return
        }
        guard idx < gridCount else { return }
        let target = idx - 1
        if target >= 0 {
            selectedEntityID = displayedEntityIDs[target]
        }
    }

    func fireSelected() async {
        guard let id = selectedEntityID,
              let entity = entities.first(where: { $0.entityID == id }) else { return }
        await fire(entity)
    }

    func copySelectedID() {
        guard let id = selectedEntityID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    // MARK: Automation affect aggregation

    /// Domains we consider "real devices" — physical things a user directly
    /// cares about. When an automation touches any of these, we ignore helper
    /// domains (input_boolean) for aggregate computation.
    private static let realDeviceDomains: Set<String> = [
        "light", "switch", "fan", "cover", "lock", "media_player"
    ]
    /// Helper/metadata domains. Included only when no real device is present.
    private static let helperDomains: Set<String> = ["input_boolean"]

    /// Per-entity state snapshot for tile rendering. Ordered by entity_id so
    /// positions are stable. Intensity is 0.0 (off) to 1.0 (full on); a dimmed
    /// light at 43% reports 0.43.
    struct TileAggregate: Sendable {
        let intensities: [Double]

        var count: Int { intensities.count }
        var allOn: Bool { !intensities.isEmpty && intensities.allSatisfy { $0 > 0 } }
        var allOff: Bool { !intensities.isEmpty && intensities.allSatisfy { $0 <= 0 } }
        var mixed: Bool { !allOn && !allOff }
        var anyOn: Bool { intensities.contains(where: { $0 > 0 }) }
    }

    /// Returns per-entity intensities across the power-domain entities an
    /// automation controls, ordered by entity_id. Nil if no usable entities yet.
    func automationAggregate(for entityID: String) -> TileAggregate? {
        guard let affectedIDs = automationAffects[entityID], !affectedIDs.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })

        let candidates: [HAEntity]
        if let override = automationOverrides[entityID] {
            // Explicit user selection — use exactly these, in stable order.
            candidates = override
                .compactMap { byID[$0] }
                .sorted { $0.entityID < $1.entityID }
        } else {
            // Heuristic: prefer real devices, fall back to helpers if no
            // real device is touched.
            let realDevices = affectedIDs
                .compactMap { byID[$0] }
                .filter { Self.realDeviceDomains.contains($0.domain) }
                .sorted { $0.entityID < $1.entityID }
            if !realDevices.isEmpty {
                candidates = realDevices
            } else {
                candidates = affectedIDs
                    .compactMap { byID[$0] }
                    .filter { Self.helperDomains.contains($0.domain) }
                    .sorted { $0.entityID < $1.entityID }
            }
        }
        guard !candidates.isEmpty else { return nil }

        return TileAggregate(intensities: candidates.map { Self.intensity(for: $0) })
    }

    /// Entities considered for aggregate by the default heuristic — used to
    /// pre-check the override editor so the dialog starts at the current state.
    func heuristicAggregateEntities(for automationID: String) -> [String] {
        guard let affectedIDs = automationAffects[automationID], !affectedIDs.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })
        let realDevices = affectedIDs
            .compactMap { byID[$0] }
            .filter { Self.realDeviceDomains.contains($0.domain) }
        if !realDevices.isEmpty {
            return realDevices.map { $0.entityID }
        }
        return affectedIDs
            .compactMap { byID[$0] }
            .filter { Self.helperDomains.contains($0.domain) }
            .map { $0.entityID }
    }

    /// Sets (or clears, with nil) the explicit override for an automation.
    /// When nil, the tile falls back to the default heuristic.
    func setAutomationOverride(_ automationID: String, selection: [String]?) {
        if let selection {
            automationOverrides[automationID] = selection
        } else {
            automationOverrides.removeValue(forKey: automationID)
        }
        let snapshot = automationOverrides
        Task { try? await persistence.saveAutomationOverrides(snapshot) }
    }

    // MARK: Watch / alerts

    /// States we treat as "nominal" — anything else on a watched entity is an
    /// alert. Covers the common passive states across domains.
    nonisolated private static let nominalStates: Set<String> = [
        "off", "closed", "locked", "home", "safe", "disarmed",
        "docked", "stopped", "idle", "ok"
    ]

    nonisolated static func isWatchAlert(_ entity: HAEntity) -> Bool {
        !nominalStates.contains(entity.state)
    }

    func isWatched(_ entityID: String) -> Bool {
        config.watchEntities.contains(entityID)
    }

    func toggleWatch(_ entity: HAEntity) {
        var new = config
        if let idx = new.watchEntities.firstIndex(of: entity.entityID) {
            new.watchEntities.remove(at: idx)
        } else {
            new.watchEntities.append(entity.entityID)
        }
        config = new
        let snapshot = new
        Task { try? await persistence.saveConfig(snapshot) }
    }

    var watchTriggered: Bool { watchTriggeredCount > 0 }

    var watchTriggeredCount: Int {
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })
        return config.watchEntities.reduce(0) { count, id in
            if let e = byID[id], Self.isWatchAlert(e) { return count + 1 }
            return count
        }
    }

    /// Returns 0.0 (off) to 1.0 (full on). Lights use brightness/255.
    /// Media players show their volume when active (playing/paused); treated as
    /// 0 when idle/off or muted. Other domains: 1 if on, 0 if off.
    static func intensity(for entity: HAEntity) -> Double {
        if entity.domain == "media_player" {
            let active: Set<String> = ["playing", "paused", "on"]
            guard active.contains(entity.state) else { return 0.0 }
            if case .bool(let muted) = entity.attributes["is_volume_muted"], muted {
                return 0.0
            }
            if case .number(let v) = entity.attributes["volume_level"] {
                return max(0, min(1, v))
            }
            return 1.0
        }
        guard isOn(entity) else { return 0.0 }
        if entity.domain == "light",
           case .number(let b) = entity.attributes["brightness"] {
            return max(0, min(1, b / 255.0))
        }
        return 1.0
    }

    /// True when the tile should render the glass-fill slider + accept vertical
    /// drag / slider input: lights that support dimming, and media_players
    /// that report a volume_level.
    static func isSlidable(_ entity: HAEntity) -> Bool {
        if isDimmable(entity) { return true }
        if entity.domain == "media_player",
           case .number = entity.attributes["volume_level"] {
            return true
        }
        return false
    }

    /// True when the entity is a light that reports any color mode other than
    /// plain on/off — i.e. brightness can be set.
    static func isDimmable(_ entity: HAEntity) -> Bool {
        guard entity.domain == "light" else { return false }
        guard case .array(let modes) = entity.attributes["supported_color_modes"] else {
            return false
        }
        for mode in modes {
            if case .string(let s) = mode, s != "onoff" {
                return true
            }
        }
        return false
    }

    /// Unified slider dispatcher: routes 0–1 slider values to the appropriate
    /// service call based on the entity's domain.
    func setTileSliderValue(_ entity: HAEntity, value: Double) async {
        let clamped = max(0, min(1, value))
        switch entity.domain {
        case "light":
            await setBrightness(entity, percent: clamped * 100)
        case "media_player":
            await setVolume(entity, level: clamped)
        default:
            break
        }
    }

    /// Sets a media_player's volume via `media_player.volume_set`.
    func setVolume(_ entity: HAEntity, level: Double) async {
        let v = max(0, min(1, level))
        do {
            try await client.callService(
                domain: "media_player",
                service: "volume_set",
                target: ["entity_id": entity.entityID],
                data: ["volume_level": v]
            )
            recordUsage(entity.entityID)
        } catch {
            status = .failed("Volume failed: \(error.localizedDescription)")
        }
    }

    enum MediaAction: Equatable {
        case next
        case previous
        case toggleMute
        case playDiagnostic
        case toggleShuffle
        case cycleRepeat
        case selectSource(String)
        case playPause
        /// Seek forward (+) or backward (-) by the given number of seconds,
        /// relative to the player's last-reported `media_position`.
        case seekRelative(Double)
        /// Seek to a specific absolute position (seconds from start).
        case seekAbsolute(Double)
        /// Fully stop playback — distinct from pause.
        case stop
        /// Cast an arbitrary audio URL to the speaker.
        case playURL(String)
    }

    // MARK: Media attribute helpers

    static func mediaShuffleOn(_ entity: HAEntity) -> Bool {
        if case .bool(let s) = entity.attributes["shuffle"] { return s }
        return false
    }

    /// HA reports repeat as "off" | "all" | "one".
    static func mediaRepeatMode(_ entity: HAEntity) -> String {
        if case .string(let r) = entity.attributes["repeat"] { return r }
        return "off"
    }

    static func mediaSources(_ entity: HAEntity) -> [String] {
        guard case .array(let list) = entity.attributes["source_list"] else { return [] }
        return list.compactMap { v in
            if case .string(let s) = v { return s }
            return nil
        }
    }

    static func mediaCurrentSource(_ entity: HAEntity) -> String? {
        if case .string(let s) = entity.attributes["source"] { return s }
        return nil
    }

    /// Estimated current playback position in seconds, factoring in time
    /// elapsed since HA last reported it (only for "playing" state).
    static func mediaPosition(for entity: HAEntity, at now: Date) -> Double? {
        guard case .number(let pos) = entity.attributes["media_position"] else { return nil }
        guard entity.state == "playing",
              case .string(let updatedStr) = entity.attributes["media_position_updated_at"],
              let updatedAt = HAClient.iso8601(updatedStr) else {
            return max(0, pos)
        }
        return max(0, pos + now.timeIntervalSince(updatedAt))
    }

    static func mediaDuration(_ entity: HAEntity) -> Double? {
        if case .number(let d) = entity.attributes["media_duration"], d > 0 {
            return d
        }
        return nil
    }

    /// Entity_ids in the same media_player group as `entity`, including itself.
    /// HA reports the full group in the `group_members` attribute.
    static func mediaGroupMembers(_ entity: HAEntity) -> [String] {
        guard case .array(let list) = entity.attributes["group_members"] else { return [] }
        return list.compactMap { v in
            if case .string(let s) = v { return s }
            return nil
        }
    }

    /// True when the media_player supports dynamic grouping through HA.
    /// Google Cast groups, for instance, don't expose this — you can play
    /// to them but can't add/remove members via HA services.
    static func mediaSupportsGrouping(_ entity: HAEntity) -> Bool {
        // media_player.MediaPlayerEntityFeature.GROUPING = 524288 (bit 19)
        guard case .number(let flags) = entity.attributes["supported_features"] else { return false }
        return (Int(flags) & 524288) != 0
    }

    /// Joins `memberID` into `leader`'s media_player group.
    func joinMediaPlayer(leader: HAEntity, memberID: String) async {
        do {
            try await client.callService(
                domain: "media_player",
                service: "join",
                target: ["entity_id": leader.entityID],
                data: ["group_members": [memberID]]
            )
            recordUsage(leader.entityID)
        } catch {
            status = .failed("Join failed: \(error.localizedDescription)")
        }
    }

    /// Unjoins the specified media_player from whatever group it's currently in.
    func unjoinMediaPlayer(entityID: String) async {
        do {
            try await client.callService(
                domain: "media_player",
                service: "unjoin",
                target: ["entity_id": entityID]
            )
        } catch {
            status = .failed("Unjoin failed: \(error.localizedDescription)")
        }
    }

    func runMediaAction(_ action: MediaAction, on entity: HAEntity) async {
        if case .playDiagnostic = action {
            await playDiagnostic(on: entity)
            return
        }

        let serviceName: String
        var data: [String: Any]? = nil
        switch action {
        case .next:
            serviceName = "media_next_track"
        case .previous:
            serviceName = "media_previous_track"
        case .toggleMute:
            serviceName = "volume_mute"
            let currentlyMuted: Bool = {
                if case .bool(let m) = entity.attributes["is_volume_muted"] { return m }
                return false
            }()
            data = ["is_volume_muted": !currentlyMuted]
        case .toggleShuffle:
            serviceName = "shuffle_set"
            data = ["shuffle": !Self.mediaShuffleOn(entity)]
        case .cycleRepeat:
            serviceName = "repeat_set"
            // Cycle: off → all → one → off
            let next: String
            switch Self.mediaRepeatMode(entity) {
            case "off": next = "all"
            case "all": next = "one"
            default: next = "off"
            }
            data = ["repeat": next]
        case .selectSource(let source):
            serviceName = "select_source"
            data = ["source": source]
        case .playPause:
            serviceName = "media_play_pause"
        case .seekRelative(let delta):
            let currentPos = Self.mediaPosition(for: entity, at: Date()) ?? 0
            let target = max(0, currentPos + delta)
            serviceName = "media_seek"
            data = ["seek_position": target]
        case .seekAbsolute(let seconds):
            serviceName = "media_seek"
            data = ["seek_position": max(0, seconds)]
        case .stop:
            serviceName = "media_stop"
        case .playURL(let url):
            serviceName = "play_media"
            data = [
                "media_content_id": url,
                "media_content_type": "music"
            ]
        case .playDiagnostic:
            return
        }
        do {
            try await client.callService(
                domain: "media_player",
                service: serviceName,
                target: ["entity_id": entity.entityID],
                data: data
            )
            recordUsage(entity.entityID)
        } catch {
            status = .failed("Media action failed: \(error.localizedDescription)")
        }
    }

    private func playDiagnostic(on entity: HAEntity) async {
        let message = "Now playing the greatest hits of the 80's, 90's, and today. End of Line."
        let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? message
        let mediaID = "media-source://tts/tts.google_en_com?message=\(encoded)&language=en-us"
        do {
            try await client.callService(
                domain: "media_player",
                service: "play_media",
                target: ["entity_id": entity.entityID],
                data: [
                    "media_content_id": mediaID,
                    "media_content_type": "provider"
                ]
            )
            recordUsage(entity.entityID)
        } catch {
            status = .failed("Diagnostic failed: \(error.localizedDescription)")
        }
    }

    /// Sets a light's brightness. 0% turns it off; >0% calls light.turn_on with
    /// brightness_pct. Records usage on success.
    func setBrightness(_ entity: HAEntity, percent: Double) async {
        let pct = max(0, min(100, percent))
        do {
            if pct <= 0 {
                try await client.callService(
                    domain: "light",
                    service: "turn_off",
                    target: ["entity_id": entity.entityID]
                )
            } else {
                try await client.callService(
                    domain: "light",
                    service: "turn_on",
                    target: ["entity_id": entity.entityID],
                    data: ["brightness_pct": pct]
                )
            }
            recordUsage(entity.entityID)
        } catch {
            status = .failed("Dim failed: \(error.localizedDescription)")
        }
    }

    private static func isOn(_ entity: HAEntity) -> Bool {
        switch entity.state {
        case "on", "open", "unlocked", "playing", "home", "active": return true
        default: return false
        }
    }

    /// Fetches the config for every automation entity in parallel and caches
    /// the set of entity_ids it references. Runs after connect; silently
    /// skips automations whose config can't be fetched.
    func refreshAutomationAffects() async {
        let automations = entities.filter { $0.domain == "automation" }
        guard !automations.isEmpty else { return }

        let client = self.client
        let fetched = await withTaskGroup(of: (String, [String]).self) { group -> [String: [String]] in
            for auto in automations {
                guard case .string(let configID) = auto.attributes["id"] else { continue }
                let entityID = auto.entityID
                group.addTask {
                    do {
                        let data = try await client.getAutomationConfig(configID)
                        if let cfg = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            var set = Set<String>()
                            HomeBarStore.extractEntityIDs(from: cfg, into: &set)
                            return (entityID, Array(set))
                        }
                        return (entityID, [])
                    } catch {
                        return (entityID, [])
                    }
                }
            }
            var out: [String: [String]] = [:]
            for await (id, ids) in group {
                out[id] = ids
            }
            return out
        }
        automationAffects = fetched
    }

    nonisolated private static func extractEntityIDs(from obj: Any, into set: inout Set<String>) {
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                if key == "entity_id" {
                    if let s = value as? String { set.insert(s) }
                    else if let arr = value as? [String] { arr.forEach { set.insert($0) } }
                    else if let arr = value as? [Any] {
                        for v in arr {
                            if let s = v as? String { set.insert(s) }
                        }
                    }
                } else {
                    extractEntityIDs(from: value, into: &set)
                }
            }
        } else if let arr = obj as? [Any] {
            for v in arr { extractEntityIDs(from: v, into: &set) }
        }
    }

    // MARK: Actions

    func fire(_ entity: HAEntity) async {
        guard let call = EntityAction.primary(for: entity) else { return }
        do {
            try await client.callService(
                domain: call.domain,
                service: call.service,
                target: ["entity_id": entity.entityID]
            )
            recordUsage(entity.entityID)
        } catch {
            status = .failed("Action failed: \(error.localizedDescription)")
        }
    }
}
