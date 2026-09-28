import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateService {
    // A development installation must never replace itself with the public app.
    static var updatesEnabled: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    var isAvailable: Bool { Self.updatesEnabled }

    @ObservationIgnored
    private let updaterController: SPUStandardUpdaterController

    @ObservationIgnored
    private var automaticChecksObservation: NSKeyValueObservation?

    @ObservationIgnored
    private var canCheckObservation: NSKeyValueObservation?

    @ObservationIgnored
    private var didStart = false

    private(set) var automaticallyChecksForUpdates: Bool
    private(set) var canCheckForUpdates: Bool

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = updaterController.updater
        automaticallyChecksForUpdates = Self.updatesEnabled && updater.automaticallyChecksForUpdates
        canCheckForUpdates = Self.updatesEnabled && updater.canCheckForUpdates

        bindUpdaterState()
        syncStateFromUpdater()
    }

    func start() {
        guard Self.updatesEnabled, !didStart else { return }

        updaterController.startUpdater()
        didStart = true
        syncStateFromUpdater()
    }

    func checkForUpdates() {
        guard Self.updatesEnabled else { return }
        if !didStart {
            start()
        }

        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
        syncStateFromUpdater()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard Self.updatesEnabled else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
        syncStateFromUpdater()
    }

    private func bindUpdaterState() {
        automaticChecksObservation = updaterController.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncStateFromUpdater()
            }
        }

        canCheckObservation = updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncStateFromUpdater()
            }
        }
    }

    private func syncStateFromUpdater() {
        let updater = updaterController.updater
        automaticallyChecksForUpdates = Self.updatesEnabled && updater.automaticallyChecksForUpdates
        canCheckForUpdates = Self.updatesEnabled && updater.canCheckForUpdates
    }

}
