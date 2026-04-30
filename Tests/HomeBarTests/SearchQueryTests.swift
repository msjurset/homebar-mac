import Foundation
import Testing
@testable import HomeBar

// MARK: - Helpers

private func entity(
    _ id: String,
    state: String = "off",
    name: String? = nil,
    areaID: String? = nil
) -> HAEntity {
    var attrs: [String: HAValue] = [:]
    if let name { attrs["friendly_name"] = .string(name) }
    if let areaID { attrs["area_id"] = .string(areaID) }
    return HAEntity(entityID: id, state: state, attributes: attrs)
}

private func matches(
    _ input: String,
    _ e: HAEntity,
    areas: [String: String] = [:],
    watchedIDs: Set<String> = []
) -> Bool {
    let q = SearchQuery.parse(input)
    return q.matches(
        e,
        areaName: { areas[$0] },
        isWatched: { watchedIDs.contains($0) }
    )
}

// MARK: - Parser

@Test func parseEmpty() {
    let q = SearchQuery.parse("")
    #expect(q.isEmpty)
}

@Test func parsePlainText() {
    let q = SearchQuery.parse("kitchen light")
    #expect(q.tokens.isEmpty)
    #expect(q.freeText == ["kitchen", "light"])
}

@Test func parseIsToken() {
    let q = SearchQuery.parse("is:watched")
    #expect(q.tokens == [.isFacet(.watched)])
    #expect(q.freeText.isEmpty)
}

@Test func parseDomainToken() {
    let q = SearchQuery.parse("domain:Light")
    #expect(q.tokens == [.domain("light")])
}

@Test func parseMixedTokensAndText() {
    let q = SearchQuery.parse("is:on domain:switch kitchen")
    #expect(q.tokens == [.isFacet(.on), .domain("switch")])
    #expect(q.freeText == ["kitchen"])
}

@Test func parseUnknownKeyFallsThroughAsText() {
    let q = SearchQuery.parse("color:red")
    #expect(q.tokens.isEmpty)
    #expect(q.freeText == ["color:red"])
}

@Test func parseEmptyValueIsFreeText() {
    let q = SearchQuery.parse("domain:")
    #expect(q.tokens.isEmpty)
    #expect(q.freeText == ["domain:"])
}

// MARK: - Filter

@Test @MainActor func isWatchedMatches() {
    let e = entity("switch.fan", state: "on")
    #expect(matches("is:watched", e, watchedIDs: ["switch.fan"]))
    #expect(!matches("is:watched", e, watchedIDs: []))
}

@Test @MainActor func isAlertingRequiresWatchedAndAlert() {
    let on = entity("switch.fan", state: "on")
    let off = entity("switch.fan", state: "off")
    #expect(matches("is:alerting", on, watchedIDs: ["switch.fan"]))
    #expect(!matches("is:alerting", off, watchedIDs: ["switch.fan"]))
    #expect(!matches("is:alerting", on, watchedIDs: []))
}

@Test @MainActor func isOnIsOff() {
    let on = entity("light.a", state: "on")
    let off = entity("light.a", state: "off")
    #expect(matches("is:on", on))
    #expect(!matches("is:on", off))
    #expect(matches("is:off", off))
    #expect(!matches("is:off", on))
}

@Test @MainActor func domainFilter() {
    let light = entity("light.a", state: "on")
    let sw = entity("switch.b", state: "on")
    #expect(matches("domain:light", light))
    #expect(!matches("domain:light", sw))
}

@Test @MainActor func areaFilterNormalizesSpaces() {
    let e = entity("light.a", areaID: "kitchen_island")
    let areas = ["kitchen_island": "Kitchen Island"]
    #expect(matches("area:kitchen_island", e, areas: areas))
    #expect(matches("area:Kitchen_Island", e, areas: areas))
}

@Test @MainActor func freeTextMatchesName() {
    let e = entity("light.a", name: "Reading Lamp")
    #expect(matches("reading", e))
    #expect(matches("lamp", e))
    #expect(!matches("floor", e))
}

@Test @MainActor func emptyFreeTextDoesNotFilterOut() {
    // Regression for the Swift `contains("")` quirk.
    let e = entity("light.a", name: "Lamp")
    let q = SearchQuery(tokens: [.isFacet(.off)], freeText: [""])
    #expect(q.matches(e, areaName: { _ in nil }, isWatched: { _ in false }))
}

@Test @MainActor func tokensCombineWithFreeText() {
    let light = entity("light.kitchen", state: "on", name: "Kitchen Ceiling")
    let sw = entity("switch.kitchen", state: "on", name: "Kitchen Fan")
    #expect(matches("domain:light kitchen", light))
    #expect(!matches("domain:light kitchen", sw))
}

// MARK: - Suggestion engine

@Test func suggestKeysWhenBareWord() {
    let ctx = SearchSuggestion.Context(
        input: "is",
        cursor: 2,
        domains: [],
        areaNames: [],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["is:"])
    #expect(r?.addTrailingSpace == false)
}

@Test func suggestAllKeysWhenEmpty() {
    let ctx = SearchSuggestion.Context(
        input: "",
        cursor: 0,
        domains: [],
        areaNames: [],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["is:", "domain:", "area:"])
}

@Test func suggestIsValuesAfterColon() {
    let ctx = SearchSuggestion.Context(
        input: "is:",
        cursor: 3,
        domains: [],
        areaNames: [],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["is:watched", "is:alerting", "is:on", "is:off"])
    #expect(r?.addTrailingSpace == true)
}

@Test func suggestIsValuesFilteredByPartial() {
    let ctx = SearchSuggestion.Context(
        input: "is:wa",
        cursor: 5,
        domains: [],
        areaNames: [],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["is:watched"])
}

@Test func suggestExcludesUsedValues() {
    let ctx = SearchSuggestion.Context(
        input: "is:watched is:",
        cursor: 14,
        domains: [],
        areaNames: [],
        alreadyUsedTokens: [.isFacet(.watched)]
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["is:alerting", "is:on", "is:off"])
}

@Test func suggestDomainValuesFromContext() {
    let ctx = SearchSuggestion.Context(
        input: "domain:",
        cursor: 7,
        domains: ["light", "switch", "light", "fan"],
        areaNames: [],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["domain:fan", "domain:light", "domain:switch"])
}

@Test func suggestAreaValuesUnderscored() {
    let ctx = SearchSuggestion.Context(
        input: "area:",
        cursor: 5,
        domains: [],
        areaNames: ["Kitchen Island", "Living Room"],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.suggestions == ["area:kitchen_island", "area:living_room"])
}

@Test func suggestReplaceRangeCoversCurrentWord() {
    let ctx = SearchSuggestion.Context(
        input: "kitchen is:wa",
        cursor: 13,
        domains: [],
        areaNames: [],
        alreadyUsedTokens: []
    )
    let r = SearchSuggestion.compute(ctx)
    #expect(r?.replaceRange == NSRange(location: 8, length: 5))
    #expect(r?.suggestions == ["is:watched"])
}
