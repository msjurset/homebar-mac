import Testing
@testable import HomeBar

@Test @MainActor func lightPrimaryIsToggle() {
    let e = HAEntity(entityID: "light.x", state: "on", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.domain == "light")
    #expect(call?.service == "toggle")
}

@Test @MainActor func scriptPrimaryIsTurnOn() {
    let e = HAEntity(entityID: "script.x", state: "off", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.domain == "script")
    #expect(call?.service == "turn_on")
}

@Test @MainActor func automationPrimaryIsTrigger() {
    let e = HAEntity(entityID: "automation.x", state: "on", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.domain == "automation")
    #expect(call?.service == "trigger")
}

@Test @MainActor func scenePrimaryIsTurnOn() {
    let e = HAEntity(entityID: "scene.x", state: "off", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.domain == "scene")
    #expect(call?.service == "turn_on")
}

@Test @MainActor func coverPrimaryIsToggle() {
    let e = HAEntity(entityID: "cover.garage", state: "closed", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.domain == "cover")
    #expect(call?.service == "toggle")
}

@Test @MainActor func lockLockedPrimaryIsUnlock() {
    let e = HAEntity(entityID: "lock.front", state: "locked", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.service == "unlock")
}

@Test @MainActor func lockUnlockedPrimaryIsLock() {
    let e = HAEntity(entityID: "lock.front", state: "unlocked", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.service == "lock")
}

@Test @MainActor func mediaPlayerPrimaryIsPlayPause() {
    let e = HAEntity(entityID: "media_player.x", state: "playing", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.domain == "media_player")
    #expect(call?.service == "media_play_pause")
}

@Test @MainActor func sensorHasNoPrimaryAction() {
    let e = HAEntity(entityID: "sensor.temperature", state: "72.5", attributes: [:])
    #expect(EntityAction.primary(for: e) == nil)
    #expect(EntityAction.isStatusOnly(e))
}

@Test @MainActor func buttonPrimaryIsPress() {
    let e = HAEntity(entityID: "button.ring", state: "unknown", attributes: [:])
    let call = EntityAction.primary(for: e)
    #expect(call?.service == "press")
}
