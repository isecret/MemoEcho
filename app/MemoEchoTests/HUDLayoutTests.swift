import XCTest
@testable import MemoEcho

final class HUDLayoutTests: XCTestCase {
    func testHUDScaleIsOnePointTwo() {
        XCTAssertEqual(HUDLayout.scale, 1.2)
    }

    func testScaledCoreDimensionsMatchCurrentHUDScale() {
        XCTAssertEqual(HUDLayout.hiddenWidth, 115.2, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.activeWidth, 105.6, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.resultWidth, 86.4, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.capsuleHeight, 31.2, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.iconSize, 16.8, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.buttonSize, 21.6, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.waveformWidth, 40.8, accuracy: 0.001)
    }

    func testNoticeWidthShrinksForShortTermsAndExpandsForLongerTerms() {
        let shortWidth = HUDLayout.noticeWidth(for: "朴邻")
        let longWidth = HUDLayout.noticeWidth(for: "客户成功…")

        XCTAssertEqual(shortWidth, 86.4, accuracy: 0.001)
        XCTAssertGreaterThan(longWidth, shortWidth)
    }

    func testHUDWindowIncludesTransparentPadding() {
        XCTAssertEqual(HUDLayout.windowSize.width, HUDLayout.activeWidth + 20, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.windowSize.height, HUDLayout.capsuleHeight + 12, accuracy: 0.001)
    }

    func testHUDBottomReservedHeightUsesOnlyBottomOccupiedSpace() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let bottomDockVisibleFrame = NSRect(x: 0, y: 64, width: 1440, height: 836)
        XCTAssertEqual(
            HUDWindow.bottomReservedHeight(
                screenFrame: screenFrame,
                visibleFrame: bottomDockVisibleFrame
            ),
            64,
            accuracy: 0.001
        )

        let sideDockVisibleFrame = NSRect(x: 96, y: 0, width: 1344, height: 900)
        XCTAssertEqual(
            HUDWindow.bottomReservedHeight(
                screenFrame: screenFrame,
                visibleFrame: sideDockVisibleFrame
            ),
            0,
            accuracy: 0.001
        )
    }

    func testHUDFrameOriginKeepsSmallBaseMarginWhenBottomIsUnoccupied() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 860)

        let origin = HUDWindow.frameOrigin(
            windowSize: HUDLayout.windowSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, visibleFrame.midX - HUDLayout.windowSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, HUDLayout.baseBottomMargin, accuracy: 0.001)
    }

    func testHUDFrameOriginAddsBottomDockHeightToBaseMargin() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSRect(x: 0, y: 72, width: 1440, height: 788)

        let origin = HUDWindow.frameOrigin(
            windowSize: HUDLayout.windowSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.y, HUDLayout.baseBottomMargin + 72, accuracy: 0.001)
    }

    func testTermsUseMeasuredWidthNotCharacterCount() {
        let narrow = HUDLayout.measure(state: .notice(String(repeating: "i", count: 30)))
        let wide = HUDLayout.measure(state: .notice(String(repeating: "国", count: 30)))
        XCTAssertEqual(narrow.lines.count, 1)
        XCTAssertEqual(narrow.dismissSeconds, 2.4)
        XCTAssertEqual(wide.lines.count, 2)
        XCTAssertEqual(wide.dismissSeconds, 4)
        for text in ["词典", "客户成功", "客户成功部", "跨区域企业知识管理协作平台", "Accessibility", "SwiftUI 混排", "👨‍👩‍👧‍👦é语音"] {
            let layout = HUDLayout.measure(state: .notice(text))
            XCTAssertEqual(layout.lines.joined(), text)
            XCTAssertLessThanOrEqual(layout.capsuleSize.width, 320)
        }
    }

    func testVeryLongTermsOnlyTruncateLastLineWithoutSplittingGraphemes() {
        for glyph in ["中", "W", "👨‍👩‍👧‍👦", "é"] {
            let term = String(repeating: glyph, count: 100)
            let layout = HUDLayout.measure(state: .notice(term))
            XCTAssertEqual(layout.lines.count, 2)
            XCTAssertFalse(layout.lines[0].contains("…"))
            XCTAssertTrue(layout.lines[1].hasSuffix("…"))
            for line in layout.lines {
                XCTAssertLessThanOrEqual(HUDLayout.textWidth(line, tracking: HUDLayout.noticeTracking), layout.textWidth)
                XCTAssertTrue(line.allSatisfy { String($0) == glyph || $0 == "…" })
            }
        }
    }

    func testRecoveryLabelsRemainWholeOnNarrowScreens() {
        for action in ["设置", "重试", "复制", "继续", "继续处理已录内容"] {
            for screenWidth: CGFloat in [1440, 300, 240] {
                let layout = HUDLayout.measure(state: .failure(.recordingInterrupted), action: action, screenWidth: screenWidth)
                XCTAssertEqual(layout.lines.joined(), "录音中断")
                XCTAssertEqual(layout.actionLines.joined(), action)
                XCTAssertLessThanOrEqual(layout.panelSize.width, screenWidth)
                XCTAssertGreaterThanOrEqual(layout.capsuleSize.height, CGFloat(layout.actionLines.count) * HUDLayout.lineHeight + 12)
                XCTAssertEqual(layout.dismissSeconds, 5)
            }
        }
    }

    func testPositionFitsNegativeCoordinateScreenAndKeepsBottomWhenGrowing() {
        let screen = NSRect(x: -1200, y: -500, width: 1200, height: 800)
        let visible = NSRect(x: -1120, y: -430, width: 1120, height: 700)
        let short = HUDLayout.measure(state: .notice("词"))
        let long = HUDLayout.measure(state: .notice(String(repeating: "长", count: 60)))
        let origins = [short, long].map {
            HUDWindow.frameOrigin(windowSize: $0.panelSize, screenFrame: screen, visibleFrame: visible)
        }
        XCTAssertEqual(origins[0].y, origins[1].y)
        for (layout, origin) in zip([short, long], origins) {
            XCTAssertTrue(visible.contains(NSRect(origin: origin, size: layout.panelSize)))
        }
    }

    func testTransparentPanelPaddingAndRoundedCornersPassThrough() {
        let layout = HUDLayout.measure(state: .failure(.injectionFailed), action: "重试写入")
        let panel = layout.panelSize
        XCTAssertFalse(HUDWindow.isInsideCapsule(NSPoint(x: 2, y: panel.height / 2), panelSize: panel, capsuleSize: layout.capsuleSize))
        XCTAssertFalse(HUDWindow.isInsideCapsule(NSPoint(x: panel.width / 2, y: 2), panelSize: panel, capsuleSize: layout.capsuleSize))
        XCTAssertFalse(HUDWindow.isInsideCapsule(NSPoint(x: 10.1, y: 6.1), panelSize: panel, capsuleSize: layout.capsuleSize))
        XCTAssertTrue(HUDWindow.isInsideCapsule(NSPoint(x: panel.width / 2, y: panel.height / 2), panelSize: panel, capsuleSize: layout.capsuleSize))
    }

    func testEveryFailureAndRecoveryActionStaysSingleLineOnDesktop() {
        let reasons: [HUDFailureReason] = [.recordingInterrupted, .permissionDenied, .resourceMissing,
            .notHeard, .recognitionFailed, .polishFailed, .translationFailed, .injectionFailed]
        let actions = ["设置", "重试", "复制", "继续", "继续处理已录内容"]
        for reason in reasons {
            let plain = HUDLayout.measure(state: .failure(reason))
            XCTAssertEqual(plain.lines, [reason.shortLabel])
            for action in actions {
                let layout = HUDLayout.measure(state: .failure(reason), action: action)
                XCTAssertEqual(layout.lines, [reason.shortLabel], "Unexpected wrap: \(reason.shortLabel) / \(action)")
                XCTAssertEqual(layout.actionLines, [action], "Unexpected action wrap: \(reason.shortLabel) / \(action)")
                XCTAssertEqual(layout.capsuleSize.height, 34)
            }
        }
    }

    func testSingleLineTermsDoNotWrapAtFractionalPaddingBoundary() {
        for glyph in ["中", "i", "W", "é", "👨‍👩‍👧‍👦"] {
            for count in 1...24 {
                let term = String(repeating: glyph, count: count)
                let layout = HUDLayout.measure(state: .notice(term))
                if layout.capsuleSize.width < HUDLayout.maximumWidth {
                    XCTAssertEqual(layout.lines, [term], "Unexpected wrap below width cap: \(term)")
                    XCTAssertEqual(layout.capsuleSize.height, HUDLayout.capsuleHeight)
                }
            }
        }
    }

    func testHUDColorsAreOpaqueAndCentralized() {
        let colors = [
            HUDLayout.capsuleBackgroundColor,
            HUDLayout.capsuleInnerStrokeColor,
            HUDLayout.capsuleOuterStrokeColor,
            HUDLayout.primaryForegroundColor,
            HUDLayout.secondaryForegroundColor,
            HUDLayout.waveformColor,
            HUDLayout.cancelButtonBackgroundColor,
            HUDLayout.cancelButtonStrokeColor,
            HUDLayout.confirmButtonBackgroundColor,
            HUDLayout.confirmButtonForegroundColor,
            HUDLayout.thinkingBaseTextColor,
            HUDLayout.thinkingHighlightTextColor
        ]

        for color in colors {
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        }
    }
}
