import Testing
@testable import HomeBar

@Test @MainActor func doorOpenIsAlert() {
    let e = HAEntity(entityID: "binary_sensor.door", state: "on", attributes: [:])
    #expect(HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func doorClosedIsNotAlert() {
    let e = HAEntity(entityID: "binary_sensor.door", state: "off", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func unavailableIsNotAlert() {
    let e = HAEntity(entityID: "sensor.probe", state: "unavailable", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func unknownIsNotAlert() {
    let e = HAEntity(entityID: "sensor.probe", state: "unknown", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func personHomeIsNotAlert() {
    let e = HAEntity(entityID: "person.mark", state: "home", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func lockLockedIsNotAlert() {
    let e = HAEntity(entityID: "lock.front", state: "locked", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func coverOpenIsAlert() {
    let e = HAEntity(entityID: "cover.garage", state: "open", attributes: [:])
    #expect(HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func enabledAutomationIsNotAlert() {
    let e = HAEntity(entityID: "automation.door_open_a_while", state: "on", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func disabledAutomationIsNotAlert() {
    let e = HAEntity(entityID: "automation.door_open_a_while", state: "off", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}

@Test @MainActor func runningScriptIsNotAlert() {
    let e = HAEntity(entityID: "script.notify", state: "on", attributes: [:])
    #expect(!HomeBarStore.isWatchAlert(e))
}
