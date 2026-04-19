import Foundation

struct HAConfig: Codable, Equatable {
    var baseURL: String
    var watchEntities: [String]
    /// Optional 1Password secret reference like `op://Private/HomeAssistant/credential`.
    /// When set, the app resolves the token via `op read` on each connect
    /// instead of reading from `~/.homebar/token`.
    var tokenRef: String?
    /// Name this instance uses when filtering `homebar_speak` events by target.
    /// HA automations can aim an announcement at a specific Mac by setting
    /// `event_data.target: <instance_name>`. Default: host name.
    var instanceName: String?

    static let empty = HAConfig(baseURL: "", watchEntities: [], tokenRef: nil, instanceName: nil)

    var isConfigured: Bool { !baseURL.isEmpty }
    var usesOnePassword: Bool { !(tokenRef ?? "").isEmpty }

    /// Resolved instance name — configured value or the host name as fallback.
    var effectiveInstanceName: String {
        if let name = instanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let host = ProcessInfo.processInfo.hostName
        // hostName often includes a suffix like ".local" — trim it.
        return host.split(separator: ".").first.map(String.init) ?? host
    }

    var websocketURL: URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/api/websocket"
        return components.url
    }

    var restBaseURL: URL? {
        URL(string: baseURL)
    }
}
