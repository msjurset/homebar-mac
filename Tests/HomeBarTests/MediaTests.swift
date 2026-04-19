import Testing
import Foundation
@testable import HomeBar

// MARK: Grouping feature detection

@Test @MainActor func mediaPlayerWithGroupingBitSupports() {
    let e = HAEntity(entityID: "media_player.sonos", state: "playing",
                     attributes: ["supported_features": .number(Double(524288 | 1 | 2))])
    #expect(HomeBarStore.mediaSupportsGrouping(e))
}

@Test @MainActor func mediaPlayerWithoutGroupingBitDoesNotSupport() {
    let e = HAEntity(entityID: "media_player.cast_group", state: "off",
                     attributes: ["supported_features": .number(152461)])
    #expect(!HomeBarStore.mediaSupportsGrouping(e))
}

@Test @MainActor func missingSupportedFeaturesMeansNoGrouping() {
    let e = HAEntity(entityID: "media_player.test", state: "off", attributes: [:])
    #expect(!HomeBarStore.mediaSupportsGrouping(e))
}

// MARK: Group members

@Test @MainActor func groupMembersEmptyWhenNotReported() {
    let e = HAEntity(entityID: "media_player.test", state: "off", attributes: [:])
    #expect(HomeBarStore.mediaGroupMembers(e).isEmpty)
}

@Test @MainActor func groupMembersReturnsListedEntities() {
    let e = HAEntity(entityID: "media_player.leader", state: "playing",
                     attributes: [
                        "group_members": .array([
                            .string("media_player.leader"),
                            .string("media_player.kitchen"),
                            .string("media_player.dining")
                        ])
                     ])
    let members = HomeBarStore.mediaGroupMembers(e)
    #expect(members == ["media_player.leader", "media_player.kitchen", "media_player.dining"])
}

// MARK: Sources

@Test @MainActor func mediaSourcesReturnsStringsFromSourceList() {
    let e = HAEntity(entityID: "media_player.test", state: "on",
                     attributes: [
                        "source_list": .array([
                            .string("TV"),
                            .string("Radio"),
                            .string("Line In")
                        ])
                     ])
    #expect(HomeBarStore.mediaSources(e) == ["TV", "Radio", "Line In"])
}

@Test @MainActor func mediaCurrentSourceReturnsStringValue() {
    let e = HAEntity(entityID: "media_player.test", state: "on",
                     attributes: ["source": .string("TV")])
    #expect(HomeBarStore.mediaCurrentSource(e) == "TV")
}

@Test @MainActor func mediaCurrentSourceNilWhenMissing() {
    let e = HAEntity(entityID: "media_player.test", state: "on", attributes: [:])
    #expect(HomeBarStore.mediaCurrentSource(e) == nil)
}

// MARK: Shuffle / repeat

@Test @MainActor func shuffleOnDetected() {
    let e = HAEntity(entityID: "media_player.test", state: "playing",
                     attributes: ["shuffle": .bool(true)])
    #expect(HomeBarStore.mediaShuffleOn(e))
}

@Test @MainActor func shuffleOffWhenMissing() {
    let e = HAEntity(entityID: "media_player.test", state: "playing", attributes: [:])
    #expect(!HomeBarStore.mediaShuffleOn(e))
}

@Test @MainActor func repeatModeReturnsStringValue() {
    let e = HAEntity(entityID: "media_player.test", state: "playing",
                     attributes: ["repeat": .string("all")])
    #expect(HomeBarStore.mediaRepeatMode(e) == "all")
}

@Test @MainActor func repeatModeDefaultsToOff() {
    let e = HAEntity(entityID: "media_player.test", state: "playing", attributes: [:])
    #expect(HomeBarStore.mediaRepeatMode(e) == "off")
}

// MARK: Duration / position

@Test @MainActor func mediaDurationReturnsPositiveValue() {
    let e = HAEntity(entityID: "media_player.test", state: "playing",
                     attributes: ["media_duration": .number(180)])
    #expect(HomeBarStore.mediaDuration(e) == 180)
}

@Test @MainActor func mediaDurationNilForZeroOrMissing() {
    let zero = HAEntity(entityID: "media_player.test", state: "playing",
                        attributes: ["media_duration": .number(0)])
    #expect(HomeBarStore.mediaDuration(zero) == nil)
    let missing = HAEntity(entityID: "media_player.test", state: "playing", attributes: [:])
    #expect(HomeBarStore.mediaDuration(missing) == nil)
}

@Test @MainActor func mediaPositionForNonPlayingIsRaw() {
    let e = HAEntity(entityID: "media_player.test", state: "paused",
                     attributes: ["media_position": .number(42)])
    #expect(HomeBarStore.mediaPosition(for: e, at: Date()) == 42)
}

@Test @MainActor func mediaPositionNilWhenMissing() {
    let e = HAEntity(entityID: "media_player.test", state: "paused", attributes: [:])
    #expect(HomeBarStore.mediaPosition(for: e, at: Date()) == nil)
}
