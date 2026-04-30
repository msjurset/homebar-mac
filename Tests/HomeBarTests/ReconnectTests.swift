import Testing
@testable import HomeBar

@Test func reconnectDelayGrowsThenCaps() {
    #expect(HomeBarStore.reconnectDelay(forAttempt: 0) == 1)
    #expect(HomeBarStore.reconnectDelay(forAttempt: 1) == 2)
    #expect(HomeBarStore.reconnectDelay(forAttempt: 2) == 5)
    #expect(HomeBarStore.reconnectDelay(forAttempt: 3) == 15)
    #expect(HomeBarStore.reconnectDelay(forAttempt: 4) == 30)
    #expect(HomeBarStore.reconnectDelay(forAttempt: 5) == 30)
    #expect(HomeBarStore.reconnectDelay(forAttempt: 100) == 30)
}

@Test func reconnectDelayHandlesNegativeAttempt() {
    #expect(HomeBarStore.reconnectDelay(forAttempt: -1) == 1)
}

@Test func authFailureIsNotRetriable() {
    #expect(!HomeBarStore.isRetriableConnectError(HAClientError.authFailed("bad token")))
    #expect(!HomeBarStore.isRetriableConnectError(HAClientError.invalidURL))
}

@Test func transientFailuresAreRetriable() {
    #expect(HomeBarStore.isRetriableConnectError(HAClientError.notConnected))
    #expect(HomeBarStore.isRetriableConnectError(HAClientError.protocolError("x")))
    #expect(HomeBarStore.isRetriableConnectError(HAClientError.serverError("y")))
}

@Test func unknownErrorsAreRetriable() {
    struct NetError: Error {}
    #expect(HomeBarStore.isRetriableConnectError(NetError()))
}
