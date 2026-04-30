import Foundation

enum HAClientError: Error, LocalizedError {
    case notConnected
    case invalidURL
    case authFailed(String)
    case protocolError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Home Assistant"
        case .invalidURL: return "Invalid Home Assistant URL"
        case .authFailed(let m): return "Authentication failed: \(m)"
        case .protocolError(let m): return "Protocol error: \(m)"
        case .serverError(let m): return "Server error: \(m)"
        }
    }
}

/// Thin actor wrapping a Home Assistant WebSocket connection.
/// Handles auth handshake, request/response correlation by `id`,
/// and emits events through `eventStream`.
actor HAClient {
    private var session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<HAResult, Error>] = [:]

    private var eventContinuation: AsyncStream<HAEvent>.Continuation?
    /// Emits every `event` message received after authentication.
    let eventStream: AsyncStream<HAEvent>

    private var dropContinuation: AsyncStream<Void>.Continuation?
    /// Yields once whenever the socket drops unexpectedly (read error, server
    /// close). Does NOT yield on explicit `disconnect()` calls. Observers use
    /// this to trigger a reconnect.
    let unexpectedDisconnectStream: AsyncStream<Void>

    private(set) var isConnected: Bool = false
    private(set) var baseURL: URL?
    private var token: String = ""
    private var restBaseURL: URL?
    private var intentionalDisconnect: Bool = false

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        var econt: AsyncStream<HAEvent>.Continuation!
        self.eventStream = AsyncStream { econt = $0 }
        self.eventContinuation = econt
        var dcont: AsyncStream<Void>.Continuation!
        self.unexpectedDisconnectStream = AsyncStream { dcont = $0 }
        self.dropContinuation = dcont
    }

    // MARK: - Connection

    /// Opens the WebSocket, completes the auth handshake, and starts the receive loop.
    func connect(websocketURL: URL, token: String) async throws {
        disconnect()
        intentionalDisconnect = false
        self.baseURL = websocketURL
        self.token = token
        self.restBaseURL = Self.deriveRestURL(from: websocketURL)

        let task = session.webSocketTask(with: websocketURL)
        self.task = task
        task.resume()

        // Step 1: expect `auth_required`.
        let first = try await receiveJSON(from: task)
        guard (first["type"] as? String) == "auth_required" else {
            throw HAClientError.protocolError("expected auth_required, got: \(first)")
        }

        // Step 2: send `auth`.
        try await send(task: task, payload: ["type": "auth", "access_token": token])

        // Step 3: expect `auth_ok` or `auth_invalid`.
        let second = try await receiveJSON(from: task)
        switch second["type"] as? String {
        case "auth_ok":
            isConnected = true
            startReceiveLoop(task: task)
        case "auth_invalid":
            throw HAClientError.authFailed((second["message"] as? String) ?? "invalid token")
        default:
            throw HAClientError.protocolError("expected auth_ok, got: \(second)")
        }
    }

    func disconnect() {
        intentionalDisconnect = true
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        // Fail all in-flight requests.
        for (_, cont) in pending {
            cont.resume(throwing: HAClientError.notConnected)
        }
        pending.removeAll()
    }

    /// Sends `{type: "ping"}` and awaits the matching pong. Used as a heartbeat
    /// to detect silently-dropped sockets.
    func ping() async throws {
        _ = try await request(["type": "ping"])
    }

    // MARK: - Requests

    /// Sends a request and awaits the matching response (`id` correlation).
    /// Cancellation-aware: if the awaiting task is cancelled (e.g. heartbeat
    /// timeout racing a ping), the pending continuation is resumed with
    /// CancellationError so the caller's task group can unwind cleanly.
    @discardableResult
    func request(_ body: [String: Any]) async throws -> HAResult {
        guard let task, isConnected else { throw HAClientError.notConnected }
        let id = nextID
        nextID += 1
        var payload = body
        payload["id"] = id
        try await send(task: task, payload: payload)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelPending(id: id) }
        }
    }

    private func cancelPending(id: Int) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
        }
    }

    func getStates() async throws -> [HAEntity] {
        let result = try await request(["type": "get_states"])
        guard case .array(let items) = result else {
            throw HAClientError.protocolError("get_states returned non-array")
        }
        return items.compactMap { item in
            if case .object(let obj) = item { return Self.parseEntity(from: obj) }
            return nil
        }
    }

    func getAreas() async throws -> [HAArea] {
        let result = try await request(["type": "config/area_registry/list"])
        guard case .array(let items) = result else { return [] }
        var areas: [HAArea] = []
        for item in items {
            guard case .object(let obj) = item,
                  case .string(let id) = obj["area_id"],
                  case .string(let name) = obj["name"] else { continue }
            areas.append(HAArea(areaID: id, name: name))
        }
        return areas
    }

    /// One row per entity in HA's entity registry: entity_id → (device_id,
    /// entity-level area_id). Either may be nil. Entity-level area_id, when
    /// present, overrides the device's area.
    struct EntityRegistryEntry: Sendable {
        let entityID: String
        let deviceID: String?
        let areaID: String?
    }

    func getEntityRegistry() async throws -> [EntityRegistryEntry] {
        let result = try await request(["type": "config/entity_registry/list"])
        guard case .array(let items) = result else { return [] }
        var entries: [EntityRegistryEntry] = []
        for item in items {
            guard case .object(let obj) = item,
                  case .string(let entityID) = obj["entity_id"] else { continue }
            var deviceID: String? = nil
            if case .string(let s) = obj["device_id"] { deviceID = s }
            var areaID: String? = nil
            if case .string(let s) = obj["area_id"] { areaID = s }
            entries.append(EntityRegistryEntry(entityID: entityID, deviceID: deviceID, areaID: areaID))
        }
        return entries
    }

    /// Returns a map of device_id → area_id for every device in HA's device
    /// registry. Used to resolve an entity's area when the entity itself
    /// hasn't been individually assigned to an area.
    func getDeviceAreaMap() async throws -> [String: String] {
        let result = try await request(["type": "config/device_registry/list"])
        guard case .array(let items) = result else { return [:] }
        var map: [String: String] = [:]
        for item in items {
            guard case .object(let obj) = item,
                  case .string(let id) = obj["id"] else { continue }
            if case .string(let aid) = obj["area_id"] { map[id] = aid }
        }
        return map
    }

    func callService(domain: String, service: String, target: [String: Any]? = nil, data: [String: Any]? = nil) async throws {
        var body: [String: Any] = [
            "type": "call_service",
            "domain": domain,
            "service": service,
        ]
        if let target { body["target"] = target }
        if let data { body["service_data"] = data }
        _ = try await request(body)
    }

    func subscribeStateChanges() async throws {
        _ = try await request(["type": "subscribe_events", "event_type": "state_changed"])
    }

    func subscribePersistentNotifications() async throws {
        _ = try await request(["type": "subscribe_events", "event_type": "persistent_notifications_updated"])
    }

    /// Subscribes to a custom event the app treats as a TTS/audio-play
    /// command. HA automations/scripts fire this event to speak or play on
    /// the Mac's default output.
    func subscribeHomebarSpeak() async throws {
        _ = try await request(["type": "subscribe_events", "event_type": "homebar_speak"])
    }

    // MARK: REST

    /// Returns the raw JSON body of `GET /api/config/automation/config/<id>`.
    /// Used to discover which entities an automation touches. Returns Data
    /// (Sendable) so parsing can happen in the caller without smuggling a
    /// non-Sendable dict across the actor boundary.
    func getAutomationConfig(_ automationID: String) async throws -> Data {
        guard let base = restBaseURL else { throw HAClientError.invalidURL }
        let url = base
            .appendingPathComponent("api/config/automation/config")
            .appendingPathComponent(automationID)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw HAClientError.serverError("HTTP \(http.statusCode) for \(automationID)")
        }
        return data
    }

    private static func deriveRestURL(from wsURL: URL) -> URL? {
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = ""
        return components.url
    }

    // MARK: - Receive loop

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await task.receive()
                    let obj = try Self.parseMessage(msg)
                    await self?.handle(message: obj)
                } catch {
                    await self?.handleReceiveError(error)
                    return
                }
            }
        }
    }

    private func handle(message: [String: Any]) {
        let type = message["type"] as? String
        if (type == "result" || type == "pong"), let id = message["id"] as? Int {
            guard let cont = pending.removeValue(forKey: id) else { return }
            let success = (message["success"] as? Bool) ?? true
            if success {
                cont.resume(returning: HAResult(raw: message["result"]))
            } else {
                let errMsg = ((message["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
                cont.resume(throwing: HAClientError.serverError(errMsg))
            }
        } else if type == "event" {
            if let event = message["event"] as? [String: Any] {
                eventContinuation?.yield(HAEvent(raw: event))
            }
        }
    }

    private func handleReceiveError(_ error: Error) {
        isConnected = false
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
        if !intentionalDisconnect {
            dropContinuation?.yield()
        }
    }

    // MARK: - WebSocket helpers

    private func send(task: URLSessionWebSocketTask, payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw HAClientError.protocolError("could not encode payload")
        }
        try await task.send(.string(text))
    }

    private func receiveJSON(from task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let msg = try await task.receive()
        return try Self.parseMessage(msg)
    }

    private static func parseMessage(_ msg: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default:
            throw HAClientError.protocolError("unknown websocket message type")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HAClientError.protocolError("non-object websocket message")
        }
        return obj
    }

    // MARK: - Entity parsing

    static func parseEntity(from obj: [String: HAValue]) -> HAEntity? {
        guard case .string(let entityID) = obj["entity_id"],
              case .string(let state) = obj["state"] else { return nil }
        var attrs: [String: HAValue] = [:]
        if case .object(let a) = obj["attributes"] { attrs = a }
        var lastChanged: Date?
        if case .string(let s) = obj["last_changed"] { lastChanged = iso8601(s) }
        var lastUpdated: Date?
        if case .string(let s) = obj["last_updated"] { lastUpdated = iso8601(s) }
        return HAEntity(
            entityID: entityID,
            state: state,
            attributes: attrs,
            lastChanged: lastChanged,
            lastUpdated: lastUpdated
        )
    }

    // ISO8601DateFormatter is not Sendable; its mutation happens only during
    // setup so reads are safe to share. Marking as `nonisolated(unsafe)` avoids
    // allocating per-call during the hundreds of entity parses on snapshot.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso8601FormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso8601(_ s: String) -> Date? {
        iso8601Formatter.date(from: s) ?? iso8601FormatterPlain.date(from: s)
    }
}

// MARK: - Result / Event value shapes

/// Lightweight tagged union over typical HA response payloads.
enum HAResult: Sendable {
    case none
    case bool(Bool)
    case string(String)
    case number(Double)
    case array([HAValue])
    case object([String: HAValue])

    init(raw: Any?) {
        guard let raw else { self = .none; return }
        if raw is NSNull { self = .none; return }
        if let b = raw as? Bool { self = .bool(b); return }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            self = .number(n.doubleValue); return
        }
        if let s = raw as? String { self = .string(s); return }
        if let a = raw as? [Any] { self = .array(a.map(HAValue.from(any:))); return }
        if let o = raw as? [String: Any] {
            var conv: [String: HAValue] = [:]
            for (k, v) in o { conv[k] = HAValue.from(any: v) }
            self = .object(conv); return
        }
        self = .none
    }
}

/// Minimal representation of a received `event` payload.
struct HAEvent: Sendable {
    let raw: [String: HAValue]

    init(raw: [String: Any]) {
        var out: [String: HAValue] = [:]
        for (k, v) in raw { out[k] = HAValue.from(any: v) }
        self.raw = out
    }

    var eventType: String? {
        if case .string(let s) = raw["event_type"] { return s }
        return nil
    }

    /// For `state_changed` events, returns the entity id and the new state dict
    /// in the shape that HAClient.parseEntity expects.
    var stateChange: (entityID: String, newState: [String: HAValue])? {
        guard case .object(let data) = raw["data"],
              case .string(let eid) = data["entity_id"],
              case .object(let state) = data["new_state"] else { return nil }
        return (eid, state)
    }
}

extension HAValue {
    static func from(any v: Any) -> HAValue {
        if v is NSNull { return .null }
        if let b = v as? Bool { return .bool(b) }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = v as? String { return .string(s) }
        if let a = v as? [Any] { return .array(a.map(HAValue.from(any:))) }
        if let o = v as? [String: Any] {
            var out: [String: HAValue] = [:]
            for (k, val) in o { out[k] = HAValue.from(any: val) }
            return .object(out)
        }
        return .null
    }
}
