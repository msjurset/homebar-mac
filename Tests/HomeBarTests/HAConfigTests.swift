import Testing
@testable import HomeBar

@Test @MainActor func httpBaseURLProducesWSScheme() {
    let cfg = HAConfig(baseURL: "http://ha:8123", watchEntities: [])
    #expect(cfg.websocketURL?.absoluteString == "ws://ha:8123/api/websocket")
}

@Test @MainActor func httpsBaseURLProducesWSSScheme() {
    let cfg = HAConfig(baseURL: "https://home.example.com", watchEntities: [])
    #expect(cfg.websocketURL?.absoluteString == "wss://home.example.com/api/websocket")
}

@Test @MainActor func emptyConfigIsNotConfigured() {
    #expect(HAConfig.empty.isConfigured == false)
}

@Test @MainActor func populatedConfigIsConfigured() {
    #expect(HAConfig(baseURL: "http://ha:8123", watchEntities: []).isConfigured == true)
}

@Test @MainActor func usesOnePasswordWhenTokenRefSet() {
    let cfg = HAConfig(baseURL: "http://ha:8123", watchEntities: [],
                       tokenRef: "op://Private/HA/token")
    #expect(cfg.usesOnePassword)
}

@Test @MainActor func doesNotUseOnePasswordWhenRefEmpty() {
    let cfg = HAConfig(baseURL: "http://ha:8123", watchEntities: [], tokenRef: "")
    #expect(!cfg.usesOnePassword)
}

@Test @MainActor func instanceNameDefaultsToHostName() {
    let cfg = HAConfig(baseURL: "http://ha:8123", watchEntities: [])
    #expect(!cfg.effectiveInstanceName.isEmpty)
}

@Test @MainActor func instanceNameRespectsExplicitValue() {
    let cfg = HAConfig(baseURL: "http://ha:8123", watchEntities: [],
                       instanceName: "marks-mac")
    #expect(cfg.effectiveInstanceName == "marks-mac")
}

@Test @MainActor func instanceNameFallsBackOnWhitespaceOnly() {
    let cfg = HAConfig(baseURL: "http://ha:8123", watchEntities: [],
                       instanceName: "   ")
    #expect(cfg.effectiveInstanceName != "   ")
}
