import Testing
@testable import HomeBar

@Test @MainActor func lightOffHasZeroIntensity() {
    let e = HAEntity(entityID: "light.test", state: "off", attributes: [:])
    #expect(HomeBarStore.intensity(for: e) == 0.0)
}

@Test @MainActor func lightOnWithBrightnessMapsTo0to1() {
    let e = HAEntity(entityID: "light.test", state: "on",
                     attributes: ["brightness": .number(127)])
    let v = HomeBarStore.intensity(for: e)
    #expect(v > 0.49 && v < 0.51)
}

@Test @MainActor func lightOnWithoutBrightnessIsFullIntensity() {
    let e = HAEntity(entityID: "light.test", state: "on", attributes: [:])
    #expect(HomeBarStore.intensity(for: e) == 1.0)
}

@Test @MainActor func mediaPlayerPlayingUsesVolumeLevel() {
    let e = HAEntity(entityID: "media_player.test", state: "playing",
                     attributes: ["volume_level": .number(0.4)])
    let v = HomeBarStore.intensity(for: e)
    #expect(v > 0.39 && v < 0.41)
}

@Test @MainActor func mediaPlayerMutedIsZero() {
    let e = HAEntity(entityID: "media_player.test", state: "playing",
                     attributes: [
                        "volume_level": .number(0.8),
                        "is_volume_muted": .bool(true)
                     ])
    #expect(HomeBarStore.intensity(for: e) == 0.0)
}

@Test @MainActor func mediaPlayerOffIsZero() {
    let e = HAEntity(entityID: "media_player.test", state: "off",
                     attributes: ["volume_level": .number(0.8)])
    #expect(HomeBarStore.intensity(for: e) == 0.0)
}

@Test @MainActor func mediaPlayerPausedStillShowsVolume() {
    let e = HAEntity(entityID: "media_player.test", state: "paused",
                     attributes: ["volume_level": .number(0.25)])
    let v = HomeBarStore.intensity(for: e)
    #expect(v > 0.24 && v < 0.26)
}

@Test @MainActor func switchOnIsFullIntensity() {
    let e = HAEntity(entityID: "switch.test", state: "on", attributes: [:])
    #expect(HomeBarStore.intensity(for: e) == 1.0)
}
