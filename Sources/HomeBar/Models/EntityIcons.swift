import Foundation

/// Resolves the MDI icon name for an entity, honoring HA's custom `icon`
/// attribute when present and falling back to a reasonable per-domain default.
enum EntityIcons {
    static func name(for entity: HAEntity) -> String {
        if case .string(let icon) = entity.attributes["icon"], !icon.isEmpty {
            return icon
        }
        return defaultIcon(domain: entity.domain, attributes: entity.attributes)
    }

    private static func defaultIcon(domain: String, attributes: [String: HAValue]) -> String {
        switch domain {
        case "light": return "mdi:lightbulb"
        case "switch": return "mdi:light-switch"
        case "input_boolean": return "mdi:toggle-switch"
        case "fan": return "mdi:fan"
        case "script": return "mdi:script-text"
        case "scene": return "mdi:palette"
        case "automation": return "mdi:robot"
        case "button", "input_button": return "mdi:gesture-tap-button"
        case "cover":
            if case .string(let cls) = attributes["device_class"] {
                switch cls {
                case "garage": return "mdi:garage"
                case "door": return "mdi:door"
                case "window": return "mdi:window-closed-variant"
                case "shutter": return "mdi:window-shutter"
                case "blind", "shade": return "mdi:blinds"
                case "curtain": return "mdi:curtains"
                case "gate": return "mdi:gate"
                default: break
                }
            }
            return "mdi:window-shutter"
        case "lock": return "mdi:lock"
        case "media_player": return "mdi:speaker"
        case "sensor": return "mdi:eye"
        case "binary_sensor": return "mdi:eye-check"
        case "person": return "mdi:account"
        case "weather": return "mdi:weather-partly-cloudy"
        case "device_tracker": return "mdi:crosshairs-gps"
        case "climate": return "mdi:thermostat"
        case "remote": return "mdi:remote"
        case "select": return "mdi:form-dropdown"
        case "number": return "mdi:numeric"
        case "zone": return "mdi:map-marker-radius"
        case "sun": return "mdi:white-balance-sunny"
        default: return "mdi:help-circle-outline"
        }
    }
}
