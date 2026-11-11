import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateService: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
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
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    private let windowPresence: ApplicationWindowPresence
    private let setUpdateBadge: (String?) -> Void

    @ObservationIgnored
    private var automaticChecksObservation: NSKeyValueObservation?

    @ObservationIgnored
    private var canCheckObservation: NSKeyValueObservation?

    @ObservationIgnored
    private var didStart = false
    private var isPresentingUpdate = false

    private(set) var automaticallyChecksForUpdates = false
    private(set) var canCheckForUpdates = false

    init(
        windowPresence: ApplicationWindowPresence = ApplicationWindowPresence(),
        setUpdateBadge: @escaping (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }
    ) {
        self.windowPresence = windowPresence
        self.setUpdateBadge = setUpdateBadge
        super.init()
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

        guard updaterController.updater.canCheckForUpdates || isPresentingUpdate else { return }
        updaterController.checkForUpdates(nil)
        syncStateFromUpdater()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        isPresentingUpdate = true
        windowPresence.updateSessionOpened { [weak self] in self?.checkForUpdates() }
        if !state.userInitiated { setUpdateBadge("1") }
        syncStateFromUpdater()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        setUpdateBadge(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        isPresentingUpdate = false
        setUpdateBadge(nil)
        windowPresence.updateSessionClosed()
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
        canCheckForUpdates = Self.updatesEnabled && (updater.canCheckForUpdates || isPresentingUpdate)
    }

}
