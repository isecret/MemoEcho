import AppKit
import SwiftUI

enum HUDLayout {
    static let scale: CGFloat = 1.2

    static let hiddenWidth = scaled(96)
    static let activeWidth = scaled(88)
    static let resultWidth = scaled(72)
    static let capsuleHeight = scaled(26)
    static let baseBottomMargin = scaled(12)

    static let recordingSpacing = scaled(4)
    static let waveformSpacing = scaled(2)
    static let waveformBarWidth = scaled(3)
    static let waveformWidth = scaled(34)

    static let iconSize = scaled(14)
    static let buttonSize = scaled(18)

    static let compactVerticalPadding = scaled(3)
    static let compactHorizontalPadding = scaled(5)
    static let regularHorizontalPadding = scaled(10)
    static let noticeLeadingPadding = scaled(7.5)
    static let noticeTrailingPadding = scaled(9.2)
    static let noticeSpacing = scaled(5)

    static let textSize = scaled(10)
    static let modeTracking = scaled(0.35)
    static let resultTracking = scaled(0.6)
    static let noticeTracking = scaled(0.1)
    static let thinkingTracking = scaled(1)

    static let backgroundInnerStroke = scaled(0.5)
    static let backgroundOuterStroke = scaled(1)
    static let iconStroke = scaled(1.2)
    static let warningDotRadius = scaled(0.6)
    static let noticeFilledIconScale: CGFloat = 0.88

    static let hiddenControlOffset = scaled(1)
    static let visibleControlOffset = scaled(2)
    static let resultOffset = scaled(2)
    static let processingResultOffset = scaled(1.5)
    static let transitionYOffset = scaled(0.5)
    static let noticeIconYOffset: CGFloat = 0

    static let resetBarHeight = scaled(1)
    static let waveformMinHeight = scaled(1.2)
    static let waveformMaxHeight = scaled(12.6)

    static let capsuleBackgroundColor = NSColor(white: 0.07, alpha: 1)
    static let capsuleInnerStrokeColor = NSColor(white: 0.16, alpha: 1)
    static let capsuleOuterStrokeColor = NSColor(white: 0.24, alpha: 1)
    static let primaryForegroundColor = NSColor(white: 1, alpha: 1)
    static let secondaryForegroundColor = NSColor(white: 0.9, alpha: 1)
    static let waveformColor = NSColor(white: 1, alpha: 1)
    static let cancelButtonBackgroundColor = NSColor(white: 0.18, alpha: 1)
    static let cancelButtonStrokeColor = NSColor(white: 0.28, alpha: 1)
    static let confirmButtonBackgroundColor = NSColor(white: 1, alpha: 1)
    static let confirmButtonForegroundColor = NSColor(white: 0.07, alpha: 1)
    static let thinkingBaseTextColor = NSColor(white: 0.34, alpha: 1)
    static let thinkingHighlightTextColor = NSColor(white: 1, alpha: 1)

    static let panelPadding = NSSize(width: 10, height: 6)
    static let maximumWidth: CGFloat = 320
    static let lineHeight: CGFloat = 18
    static let actionSpacing: CGFloat = 8
    static let actionPadding: CGFloat = 6
    static let missingSignalWidth = textWidth("没收到声音", tracking: 0)
    static let windowSize = NSSize(width: activeWidth + 20, height: capsuleHeight + 12)

    static func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    static func textWidth(_ text: String, tracking: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: textSize, weight: .semibold), .kern: tracking
        ]).width) + 1 // Account for fractional SwiftUI glyph positioning.
    }

    /// Explicit Character boundaries keep emoji/combining marks intact, including long Latin tokens.
    /// The view draws these exact lines, so measurement and rendering cannot choose different wraps.
    static func textLines(_ text: String, width: CGFloat, tracking: CGFloat,
                          limit: Int? = 2) -> [String] {
        var lines: [String] = []
        var line = ""
        for character in text {
            if character == "\n" || character == "\r\n" {
                lines.append(line)
                line = ""
            } else if !line.isEmpty && textWidth(line + String(character), tracking: tracking) > width {
                lines.append(line)
                line = String(character)
            } else {
                line.append(character)
            }
        }
        lines.append(line)
        guard let limit, lines.count > limit else { return lines }
        lines = Array(lines.prefix(limit))
        while !lines[limit - 1].isEmpty && textWidth(lines[limit - 1] + "…", tracking: tracking) > width {
            lines[limit - 1].removeLast()
        }
        lines[limit - 1] += "…"
        return lines
    }

    static func measure(state: HUDState, action: String? = nil, signalMissing: Bool = false,
                        modeLabel: String? = nil, isCopyConfirmation: Bool = false, screenWidth: CGFloat = 1440) -> Presentation {
        let cap = max(1, min(maximumWidth, screenWidth - 32))
        var width = min(activeWidth, cap)
        var height = capsuleHeight
        var lines: [String] = []
        var actionLines: [String] = []
        var textArea: CGFloat = 0
        var actionArea: CGFloat = 0
        var duration: Double?
        switch state {
        case .notice(let text):
            let fixed = noticeLeadingPadding + iconSize + noticeSpacing + noticeTrailingPadding
            width = min(cap, max(resultWidth, fixed + textWidth(text, tracking: noticeTracking)))
            textArea = max(1, width - fixed)
            lines = textLines(text, width: textArea, tracking: noticeTracking)
            height = lines.count > 1 ? 50 : capsuleHeight
            duration = isCopyConfirmation ? 1.2 : (lines.count > 1 ? 4 : 2.4)
        case .failure(let reason):
            let fixed = regularHorizontalPadding * 2 + iconSize + compactHorizontalPadding
            let labelWidth = textWidth(reason.shortLabel, tracking: resultTracking)
            if let action {
                let actionFixed = actionSpacing * 2 + 1 + actionPadding * 2
                let naturalAction = textWidth(action, tracking: noticeTracking)
                let naturalWidth = fixed + labelWidth + actionFixed + naturalAction
                width = min(cap, max(resultWidth, naturalWidth))
                if naturalWidth <= cap {
                    // Each label keeps its measured width. Equal character counts can have
                    // different widths because reason and action use different tracking.
                    textArea = labelWidth
                    actionArea = naturalAction
                } else {
                    // Only constrain individual regions after the whole row hits the screen cap.
                    textArea = min(labelWidth, max(1, (width - fixed - actionFixed) * 0.5))
                    actionArea = max(1, width - fixed - textArea - actionFixed)
                }
                lines = textLines(reason.shortLabel, width: textArea, tracking: resultTracking, limit: nil)
                actionLines = textLines(action, width: actionArea, tracking: noticeTracking, limit: nil)
                height = max(34, CGFloat(max(lines.count, actionLines.count)) * lineHeight + 12)
                duration = 5
            } else {
                width = min(cap, max(resultWidth, fixed + labelWidth))
                textArea = max(1, width - fixed)
                lines = textLines(reason.shortLabel, width: textArea, tracking: resultTracking, limit: nil)
                height = max(capsuleHeight, CGFloat(lines.count) * lineHeight + 12)
                duration = 2.4
            }
        case .recording:
            if let modeLabel {
                width = min(cap, max(activeWidth, textWidth(modeLabel, tracking: modeTracking) + regularHorizontalPadding * 2))
            } else if signalMissing {
                width = min(cap, activeWidth - waveformWidth + missingSignalWidth)
            }
        default: break
        }
        return Presentation(capsuleSize: NSSize(width: width, height: height),
                            lines: lines, actionLines: actionLines, textWidth: textArea,
                            actionWidth: actionArea, dismissSeconds: duration)
    }

    struct Presentation: Equatable {
        let capsuleSize: NSSize
        var lines: [String] = []
        var actionLines: [String] = []
        var textWidth: CGFloat = 0
        var actionWidth: CGFloat = 0
        var dismissSeconds: Double?
        var panelSize: NSSize {
            NSSize(width: ceil(capsuleSize.width + panelPadding.width * 2),
                   height: ceil(capsuleSize.height + panelPadding.height * 2))
        }
        var cornerRadius: CGFloat { min(17, capsuleSize.height / 2) }
    }

    static func noticeWidth(for text: String) -> CGFloat {
        measure(state: .notice(text)).capsuleSize.width
    }
}
