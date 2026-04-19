import Testing
@testable import HomeBar

@Test @MainActor func dimmableLightIsSlidable() {
    let e = HAEntity(entityID: "light.test", state: "on",
                     attributes: ["supported_color_modes": .array([.string("brightness")])])
    #expect(HomeBarStore.isSlidable(e))
    #expect(HomeBarStore.isDimmable(e))
}

@Test @MainActor func onOffLightIsNotSlidable() {
    let e = HAEntity(entityID: "light.test", state: "on",
                     attributes: ["supported_color_modes": .array([.string("onoff")])])
    #expect(!HomeBarStore.isSlidable(e))
    #expect(!HomeBarStore.isDimmable(e))
}

@Test @MainActor func lightWithoutColorModesIsNotSlidable() {
    let e = HAEntity(entityID: "light.test", state: "on", attributes: [:])
    #expect(!HomeBarStore.isSlidable(e))
}

@Test @MainActor func mediaPlayerWithVolumeIsSlidable() {
    let e = HAEntity(entityID: "media_player.test", state: "playing",
                     attributes: ["volume_level": .number(0.5)])
    #expect(HomeBarStore.isSlidable(e))
}

@Test @MainActor func mediaPlayerWithoutVolumeIsNotSlidable() {
    let e = HAEntity(entityID: "media_player.test", state: "on", attributes: [:])
    #expect(!HomeBarStore.isSlidable(e))
}

@Test @MainActor func switchIsNotSlidable() {
    let e = HAEntity(entityID: "switch.test", state: "on", attributes: [:])
    #expect(!HomeBarStore.isSlidable(e))
}
