import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateService {
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
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates

        bindUpdaterState()
        syncStateFromUpdater()
    }

    func start() {
        guard !didStart else { return }

        updaterController.startUpdater()
        didStart = true
        syncStateFromUpdater()
    }

    func checkForUpdates() {
        if !didStart {
            start()
        }

        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
        syncStateFromUpdater()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
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
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates
    }

}
