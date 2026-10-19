import Foundation
import XCTest
@testable import MemoEcho

final class ServiceProbeNetworkRecoveryTests: XCTestCase {
    func testOnlyExplicitOfflineFailureWaitsForNetwork() {
        XCTAssertTrue(ServiceProbeFailure.classify(URLError(.notConnectedToInternet)).waitsForNetwork)
        for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .secureConnectionFailed] {
            XCTAssertFalse(ServiceProbeFailure.classify(URLError(code)).waitsForNetwork)
        }
    }

    func testNetworkRecoveryResumesOnceAndStopsObserving() async throws {
        let started = expectation(description: "path observation started")
        let monitor = TestProbePathMonitor(onStart: { started.fulfill() })
        let task = Task { try await ServiceProbeNetworkRecovery.waitUntilAvailable(monitor: monitor) }
        await fulfillment(of: [started], timeout: 2)
        monitor.emit(false)
        XCTAssertEqual(monitor.cancelCount, 0)
        monitor.emit(true)
        monitor.emit(true)
        try await task.value
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.cancelCount, 1)
        XCTAssertFalse(monitor.hasHandler)
    }

    func testCancellingOfflineWaitClosesMonitorAndResumesWithCancellation() async throws {
        let started = expectation(description: "path observation started")
        let monitor = TestProbePathMonitor(onStart: { started.fulfill() })
        let task = Task { try await ServiceProbeNetworkRecovery.waitUntilAvailable(monitor: monitor) }
        await fulfillment(of: [started], timeout: 2)
        monitor.emit(false)
        task.cancel()
        do { try await task.value; XCTFail("Offline wait must be cancellable") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.cancelCount, 1)
        XCTAssertFalse(monitor.hasHandler)
        monitor.emit(true)
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    func testAlreadyCancelledWaitDoesNotStartMonitor() async throws {
        let monitor = TestProbePathMonitor()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ServiceProbeNetworkRecovery.waitUntilAvailable(monitor: monitor)
        }
        do { try await task.value; XCTFail("Cancelled wait must fail before observing") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(monitor.startCount, 0)
        XCTAssertEqual(monitor.cancelCount, 1)
        XCTAssertFalse(monitor.hasHandler)
    }
}

private final class TestProbePathMonitor: ServiceProbeNetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?
    private var starts = 0
    private var cancels = 0
    private let onStart: @Sendable () -> Void

    init(onStart: @escaping @Sendable () -> Void = {}) { self.onStart = onStart }
    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancels } }
    var hasHandler: Bool { lock.withLock { handler != nil } }

    func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { starts += 1; handler = onUpdate }
        onStart()
    }

    func cancel() { lock.withLock { cancels += 1; handler = nil } }
    func emit(_ available: Bool) { lock.withLock { handler }?(available) }
}
