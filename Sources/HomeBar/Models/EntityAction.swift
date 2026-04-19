import Foundation

struct ServiceCall: Sendable {
    let domain: String
    let service: String
}

enum EntityAction {
    /// Maps an entity to the appropriate service call for a "primary click" on
    /// its tile. Returns nil for domains we don't act on (sensors, binary sensors, etc.).
    static func primary(for entity: HAEntity) -> ServiceCall? {
        switch entity.domain {
        case "light", "switch", "input_boolean", "fan", "siren", "humidifier":
            return ServiceCall(domain: entity.domain, service: "toggle")
        case "script":
            return ServiceCall(domain: "script", service: "turn_on")
        case "scene":
            return ServiceCall(domain: "scene", service: "turn_on")
        case "automation":
            return ServiceCall(domain: "automation", service: "trigger")
        case "button", "input_button":
            return ServiceCall(domain: entity.domain, service: "press")
        case "cover":
            return ServiceCall(domain: "cover", service: "toggle")
        case "lock":
            return ServiceCall(domain: "lock", service: entity.state == "locked" ? "unlock" : "lock")
        case "media_player":
            return ServiceCall(domain: "media_player", service: "media_play_pause")
        default:
            return nil
        }
    }

    /// True if the tile is meant to be read-only status (no tap action).
    static func isStatusOnly(_ entity: HAEntity) -> Bool {
        primary(for: entity) == nil
    }
}
