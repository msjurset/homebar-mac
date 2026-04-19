import Foundation

struct HAEntity: Identifiable, Equatable, Sendable {
    let entityID: String
    var state: String
    var attributes: [String: HAValue]
    var lastChanged: Date?
    var lastUpdated: Date?

    var id: String { entityID }

    var domain: String {
        entityID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    }

    var friendlyName: String {
        if case .string(let s) = attributes["friendly_name"] { return s }
        return entityID
    }

    var areaID: String? {
        if case .string(let s) = attributes["area_id"] { return s }
        return nil
    }
}

/// Minimal JSON value model so we can decode arbitrary attribute payloads.
enum HAValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([HAValue])
    case object([String: HAValue])
    case null
}

extension HAValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([HAValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: HAValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported HA value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}
