import Foundation
import SwiftUI
import Sparkle

@MainActor
final class UpdaterService {
    static let shared = UpdaterService()

    let controller: SPUStandardUpdaterController

    private init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var timer: Timer?

    init(updater: SPUUpdater) {
        // Poll canCheckForUpdates since KVO keypaths don't work with MainActor in Swift 6.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        canCheckForUpdates = updater.canCheckForUpdates
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var vm: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.vm = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!vm.canCheckForUpdates)
    }
}
