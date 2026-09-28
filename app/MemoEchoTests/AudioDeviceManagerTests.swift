import XCTest
@testable import MemoEcho

final class AudioDeviceManagerTests: XCTestCase {
    private let inputs = [
        AudioInputDevice(id: "internal", name: "Mac microphone", transport: .builtIn),
        AudioInputDevice(id: "headset", name: "Headset", transport: .bluetooth),
        AudioInputDevice(id: "usb", name: "USB microphone", transport: .external),
    ]

    func testAutomaticSelectionAvoidsBluetoothInputWhenBuiltInIsAvailable() {
        XCTAssertEqual(resolve(.automatic), "internal")
        XCTAssertEqual(resolve(.systemDefault), "headset", "System default must keep its documented meaning")
        XCTAssertEqual(resolve(.init(selectedDeviceID: "headset")), "headset")
    }

    func testAutomaticSelectionRespectsClamshellAvailabilityAndExternalMicrophones() {
        XCTAssertEqual(resolve(.automatic, lidClosed: true), "headset")
        var muted = inputs
        muted[0].isUsable = false
        XCTAssertEqual(resolve(.automatic, devices: muted), "headset")
        XCTAssertEqual(resolve(.automatic, devices: Array(inputs.dropFirst())), "headset")
        XCTAssertEqual(resolve(.automatic, defaultID: "usb"), "usb")
        XCTAssertEqual(resolve(.automatic, output: .builtIn), "headset")
        XCTAssertNil(resolve(.automatic, devices: [], defaultID: nil))
        XCTAssertEqual(resolve(.init(selectedDeviceID: "disconnected")), "headset")
    }

    func testTypelessStartDelayUsesSameDeviceThenAirPodsThenImmediatePlayback() {
        XCTAssertEqual(AudioDeviceManager.startSoundDelayMilliseconds(inputID: 3, outputID: 3, outputName: "Headset"), 1_200)
        XCTAssertEqual(AudioDeviceManager.startSoundDelayMilliseconds(inputID: 3, outputID: 3, outputName: "AirPods Pro"), 1_200)
        XCTAssertEqual(AudioDeviceManager.startSoundDelayMilliseconds(inputID: 1, outputID: 3, outputName: "AIRPODS Pro"), 300)
        XCTAssertEqual(AudioDeviceManager.startSoundDelayMilliseconds(inputID: 1, outputID: 2, outputName: "Speakers"), 0)
        XCTAssertEqual(AudioDeviceManager.startSoundDelayMilliseconds(inputID: nil, outputID: nil, outputName: nil), 0)
        XCTAssertEqual(AudioDeviceManager.startSoundDelayMilliseconds(inputID: 0, outputID: 0, outputName: nil), 0)
    }

    private func resolve(_ config: AudioInputConfig, devices: [AudioInputDevice]? = nil,
                         defaultID: String? = "headset", output: AudioDeviceTransport = .bluetooth,
                         lidClosed: Bool = false) -> String? {
        AudioDeviceManager.resolveInputID(config: config, devices: devices ?? inputs,
                                          defaultInputID: defaultID, outputTransport: output, lidClosed: lidClosed)
    }

    func testSystemDefaultAggregateDevicePrefixesAreHidden() {
        XCTAssertTrue(AudioDeviceManager.isSystemDefaultAggregateDeviceID(
            "CADefaultDeviceAggregate-1",
            localizedName: "系统默认"
        ))
        XCTAssertTrue(AudioDeviceManager.isSystemDefaultAggregateDeviceID(
            "input-1",
            localizedName: "ICADefaultDeviceAggregate-14713-4"
        ))
        XCTAssertFalse(AudioDeviceManager.isSystemDefaultAggregateDeviceID(
            "BuiltInMicrophoneDevice",
            localizedName: "MacBook Pro 麦克风"
        ))
    }

    func testSystemDefaultDisplayNameShowsNoMicrophoneForAggregateWithoutDevices() {
        let displayName = AudioDeviceManager.systemDefaultDeviceDisplayName(
            defaultDeviceID: "ICADefaultDeviceAggregate-14713-4",
            defaultDeviceName: "ICADefaultDeviceAggregate-14713-4",
            availableDevices: []
        )

        XCTAssertEqual(displayName, "未找到可用麦克风")
    }

    func testSystemDefaultDisplayNameFallsBackToAvailableMicrophoneForAggregate() {
        let displayName = AudioDeviceManager.systemDefaultDeviceDisplayName(
            defaultDeviceID: "CADefaultDeviceAggregate-1",
            defaultDeviceName: "CADefaultDeviceAggregate-1",
            availableDevices: [
                AudioInputDevice(id: "studio-display", name: "Studio Display 麦克风"),
            ]
        )

        XCTAssertEqual(displayName, "Studio Display 麦克风")
    }

    func testSystemDefaultDisplayNameKeepsHumanReadableDefaultName() {
        let displayName = AudioDeviceManager.systemDefaultDeviceDisplayName(
            defaultDeviceID: "built-in",
            defaultDeviceName: "MacBook Pro 麦克风",
            availableDevices: []
        )

        XCTAssertEqual(displayName, "MacBook Pro 麦克风")
    }

    func testSystemDefaultMenuTitleShowsNoMicrophoneDirectly() {
        XCTAssertEqual(
            AudioDeviceManager.systemDefaultMenuItemTitle(displayName: AudioDeviceManager.noInputDeviceDisplayName),
            AudioDeviceManager.noInputDeviceDisplayName
        )
    }

    func testSystemDefaultMenuTitleIncludesDefaultDeviceName() {
        XCTAssertEqual(
            AudioDeviceManager.systemDefaultMenuItemTitle(displayName: "MacBook Pro 麦克风"),
            "系统默认(MacBook Pro 麦克风)"
        )
    }
}
