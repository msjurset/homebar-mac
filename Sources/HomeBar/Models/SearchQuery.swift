import Foundation

/// Token-based search grammar. Input is split on whitespace; each piece is
/// either a `key:value` token or free text. Free text matches name / entity_id
/// / area. Tokens apply as AND filters.
///
/// Supported keys:
/// - `is:` — `watched`, `alerting`, `on`, `off`
/// - `domain:` — any HA domain (e.g. `light`, `switch`, `fan`)
/// - `area:` — area name (spaces allowed via `_`, matched case-insensitively)
struct SearchQuery: Equatable {
    enum IsFacet: String, CaseIterable, Equatable {
        case watched
        case alerting
        case on
        case off
    }

    enum Token: Equatable {
        case isFacet(IsFacet)
        case domain(String)
        case area(String)
    }

    var tokens: [Token]
    var freeText: [String]

    static let empty = SearchQuery(tokens: [], freeText: [])

    var isEmpty: Bool { tokens.isEmpty && freeText.isEmpty }

    static func parse(_ input: String) -> SearchQuery {
        let parts = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var tokens: [Token] = []
        var free: [String] = []
        for part in parts {
            if let token = parseToken(part) {
                tokens.append(token)
            } else {
                free.append(part)
            }
        }
        return SearchQuery(tokens: tokens, freeText: free)
    }

    private static func parseToken(_ s: String) -> Token? {
        guard let colonIdx = s.firstIndex(of: ":") else { return nil }
        let key = s[s.startIndex..<colonIdx].lowercased()
        let rawValue = String(s[s.index(after: colonIdx)...])
        guard !rawValue.isEmpty else { return nil }
        let value = rawValue.lowercased()
        switch key {
        case "is":
            guard let f = IsFacet(rawValue: value) else { return nil }
            return .isFacet(f)
        case "domain":
            return .domain(value)
        case "area":
            return .area(value)
        default:
            return nil
        }
    }

    /// Returns true if the entity satisfies every token and at least one free-text
    /// fragment appears somewhere searchable (when any free text is present).
    /// The default `areaID` resolver only checks state attributes; callers
    /// should pass a richer resolver (e.g. `HomeBarStore.resolvedAreaID`)
    /// that consults the entity / device registry to catch entities whose
    /// area is set on the device rather than directly on the state.
    func matches(
        _ entity: HAEntity,
        areaName: (String) -> String?,
        areaID: (HAEntity) -> String? = { $0.areaID },
        isWatched: (String) -> Bool
    ) -> Bool {
        for token in tokens {
            switch token {
            case .isFacet(.watched):
                guard isWatched(entity.entityID) else { return false }
            case .isFacet(.alerting):
                guard isWatched(entity.entityID),
                      HomeBarStore.isWatchAlert(entity) else { return false }
            case .isFacet(.on):
                guard Self.entityIsOn(entity) else { return false }
            case .isFacet(.off):
                guard !Self.entityIsOn(entity) else { return false }
            case .domain(let d):
                guard entity.domain.lowercased() == d else { return false }
            case .area(let a):
                let needle = Self.normalizeArea(a)
                let entityArea = areaID(entity).flatMap(areaName).map(Self.normalizeArea) ?? ""
                guard entityArea == needle else { return false }
            }
        }
        guard !freeText.isEmpty else { return true }
        let haystack = Self.haystack(for: entity, areaName: areaName, areaID: areaID)
        for needle in freeText {
            let n = needle.lowercased()
            // Guard against the Swift `contains("")` quirk.
            guard n.isEmpty || haystack.contains(n) else { return false }
        }
        return true
    }

    private static func haystack(
        for entity: HAEntity,
        areaName: (String) -> String?,
        areaID: (HAEntity) -> String?
    ) -> String {
        var parts = [entity.friendlyName.lowercased(), entity.entityID.lowercased()]
        if let area = areaID(entity).flatMap(areaName) {
            parts.append(area.lowercased())
        }
        return parts.joined(separator: " ")
    }

    static func normalizeArea(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func entityIsOn(_ entity: HAEntity) -> Bool {
        switch entity.state {
        case "on", "open", "unlocked", "playing", "home", "active": return true
        default: return false
        }
    }
}
