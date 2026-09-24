import XCTest
@testable import MemoEcho

@MainActor
final class RecordingStartGateTests: XCTestCase {
    private let ready = VoiceInputReadiness(hotkey: .ready, microphone: .ready, accessibility: .ready, asr: .ready, llm: .ready)

    func testStartsOnlyAfterAllRequirementsAreReady() {
        let gate = RecordingStartGate()
        var starts = 0
        var routes: [SetupStep] = []
        gate.attemptStart(isAuthorizing: false, refresh: { ready },
                          showRecovery: { routes.append($0) }, startRecording: { starts += 1 })
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(routes.isEmpty)
    }

    func testEveryMissingRequirementBlocksSessionAndRoutesInSetupOrder() {
        let gate = RecordingStartGate()
        let variants: [(WritableKeyPath<VoiceInputReadiness, ReadinessStatus>, SetupStep)] = [
            (\.asr, .asr), (\.llm, .llm), (\.microphone, .permissions), (\.accessibility, .permissions), (\.hotkey, .hotkey)
        ]
        for (key, step) in variants {
            for status in [ReadinessStatus.blocked("缺失"), .pending("验证中")] {
                var snapshot = ready
                snapshot[keyPath: key] = status
                var routed: SetupStep?
                gate.attemptStart(isAuthorizing: false, refresh: { snapshot },
                                  showRecovery: { routed = $0 }, startRecording: { XCTFail("不能创建会话") })
                XCTAssertEqual(routed, step)
            }
        }
    }

    func testOptionalTrialWindowDoesNotBlockReadyExternalRecording() {
        let gate = RecordingStartGate()
        var starts = 0
        gate.attemptStart(isAuthorizing: false, refresh: { ready },
                          showRecovery: { _ in XCTFail() }, startRecording: { starts += 1 })
        XCTAssertEqual(starts, 1)
    }

    func testRepeatedHotkeysDoNothingDuringAuthorization() {
        let gate = RecordingStartGate()
        for _ in 0..<10 {
            gate.attemptStart(isAuthorizing: true, refresh: { XCTFail("不应重复验证"); return ready },
                              showRecovery: { _ in XCTFail("不应打开窗口") }, startRecording: { XCTFail("不能创建会话") })
        }
    }

    func testRefreshIsDynamicAndNeverAutomaticallyStartsAfterRecovery() {
        let gate = RecordingStartGate()
        var snapshot = ready
        snapshot.microphone = .blocked("已撤销")
        var starts = 0
        var routes = 0
        let attempt = {
            gate.attemptStart(isAuthorizing: false, refresh: { snapshot },
                              showRecovery: { _ in routes += 1 }, startRecording: { starts += 1 })
        }
        attempt()
        snapshot = ready
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(routes, 1)
        attempt()
        XCTAssertEqual(starts, 1)
    }

    func testReentrantHotkeyIsSingleFlight() {
        let gate = RecordingStartGate()
        var starts = 0
        gate.attemptStart(isAuthorizing: false, refresh: {
            gate.attemptStart(isAuthorizing: false,
                              refresh: { ready }, showRecovery: { _ in XCTFail() }, startRecording: { XCTFail() })
            return ready
        }, showRecovery: { _ in XCTFail() }, startRecording: { starts += 1 })
        XCTAssertEqual(starts, 1)
    }
}
