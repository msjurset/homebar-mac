import Testing
@testable import HomeBar

@Test @MainActor func haCustomIconTakesPrecedence() {
    let e = HAEntity(entityID: "fan.chair", state: "on",
                     attributes: ["icon": .string("mdi:chair")])
    #expect(EntityIcons.name(for: e) == "mdi:chair")
}

@Test @MainActor func lightDomainDefaults() {
    let e = HAEntity(entityID: "light.x", state: "on", attributes: [:])
    #expect(EntityIcons.name(for: e) == "mdi:lightbulb")
}

@Test @MainActor func automationDomainDefault() {
    let e = HAEntity(entityID: "automation.x", state: "on", attributes: [:])
    #expect(EntityIcons.name(for: e) == "mdi:robot")
}

@Test @MainActor func coverGarageDeviceClass() {
    let e = HAEntity(entityID: "cover.door_a", state: "closed",
                     attributes: ["device_class": .string("garage")])
    #expect(EntityIcons.name(for: e) == "mdi:garage")
}

@Test @MainActor func coverDoorDeviceClass() {
    let e = HAEntity(entityID: "cover.front", state: "closed",
                     attributes: ["device_class": .string("door")])
    #expect(EntityIcons.name(for: e) == "mdi:door")
}

@Test @MainActor func unknownDomainGetsHelpIcon() {
    let e = HAEntity(entityID: "fizzbuzz.x", state: "x", attributes: [:])
    #expect(EntityIcons.name(for: e) == "mdi:help-circle-outline")
}
