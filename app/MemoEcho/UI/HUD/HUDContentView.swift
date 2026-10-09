import SwiftUI

/// State and size are published together by the controller after the panel can contain them.
struct HUDContentView: View {
    let controller: HUDFeedbackController
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var actionFocused: Bool

    var body: some View {
        let layout = controller.presentation
        let generation = controller.presentationGeneration
        Group {
            switch controller.hudState {
            case .hidden: Color.clear
            case .hotkeyPending, .recording:
                if let label = controller.modeCueLabel {
                    Text(label)
                        .font(.system(size: HUDLayout.textSize, weight: .semibold))
                        .tracking(HUDLayout.modeTracking)
                } else {
                    HUDRecordingContent(
                        barHeights: reduceMotion ? [2, 5, 8, 12, 8, 5, 2] : controller.barHeights,
                        signalMissing: controller.recordingSignalMissing,
                        controlsOpacity: controller.hudState == .hotkeyPending ? 0 : 1,
                        waveformOpacity: controller.hudState == .hotkeyPending ? 0.45 : 1,
                        onCancel: onCancel, onConfirm: onConfirm
                    )
                }
            case .processing: HUDThinkingContent()
            case .notice(let text):
                HStack(spacing: HUDLayout.noticeSpacing) {
                    icon(controller.isCopyConfirmation ? "check" : "dictionary")
                    measuredText(layout.lines, width: layout.textWidth, tracking: HUDLayout.noticeTracking)
                }
                .padding(.leading, HUDLayout.noticeLeadingPadding)
                .padding(.trailing, HUDLayout.noticeTrailingPadding)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
            case .failure(let reason):
                HStack(spacing: 0) {
                    icon("warn").padding(.trailing, HUDLayout.compactHorizontalPadding)
                    measuredText(layout.lines, width: layout.textWidth, tracking: HUDLayout.resultTracking)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(reason.shortLabel)
                    if let action = controller.recoveryActionTitle {
                        Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16)
                            .padding(.horizontal, HUDLayout.actionSpacing)
                            .accessibilityHidden(true)
                        Button {
                            controller.performRecoveryAction(expectedGeneration: generation)
                        } label: {
                            measuredText(layout.actionLines, width: layout.actionWidth,
                                         tracking: HUDLayout.noticeTracking)
                                .padding(.horizontal, HUDLayout.actionPadding)
                                .frame(minHeight: 28)
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(HUDRecoveryButtonStyle())
                        .disabled(controller.recoveryActionPerformed)
                        .accessibilityLabel(action)
                        .accessibilityFocused($actionFocused)
                    }
                }
                .padding(.horizontal, HUDLayout.regularHorizontalPadding)
            }
        }
        .foregroundStyle(Color(nsColor: HUDLayout.secondaryForegroundColor))
        .frame(width: layout.capsuleSize.width, height: layout.capsuleSize.height)
        .background {
            HUDCapsuleBackground(cornerRadius: layout.cornerRadius)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: layout.capsuleSize)
        }
        .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
        .onChange(of: actionFocused) { _, value in
            controller.setRecoveryAccessibilityFocus(value, generation: generation)
        }
        .onChange(of: generation) { _, _ in actionFocused = false }
        .padding(.bottom, HUDLayout.panelPadding.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func icon(_ type: String) -> some View {
        HUDIcon(type: type).frame(width: HUDLayout.iconSize, height: HUDLayout.iconSize)
            .foregroundStyle(Color(nsColor: HUDLayout.primaryForegroundColor))
            .accessibilityHidden(true)
    }

    private func measuredText(_ lines: [String], width: CGFloat, tracking: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: HUDLayout.textSize, weight: .semibold))
                    .tracking(tracking).fixedSize().frame(height: HUDLayout.lineHeight)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct HUDRecoveryButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.22 : (hovered ? 0.12 : 0.04)),
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

// MARK: - Shared Recording Visuals

/// 引导仅驱动预览波形；胶囊、按钮、间距和实际录音 HUD 使用同一实现。
struct HUDRecordingPreview: View {
    let reduceMotion: Bool
    var isPending = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 4
            let profile: [CGFloat] = [0.10, 0.42, 0.62, 0.88, 0.62, 0.42, 0.10]
            let heights = profile.enumerated().map { index, weight in
                HUDLayout.waveformMinHeight + (HUDLayout.waveformMaxHeight - HUDLayout.waveformMinHeight)
                    * weight * (0.7 + 0.3 * CGFloat(abs(sin(phase + Double(index) * 0.5))))
            }
            HUDRecordingContent(
                barHeights: isPending ? Array(repeating: HUDLayout.resetBarHeight, count: 7) : heights,
                controlsOpacity: isPending ? 0 : 1,
                waveformOpacity: isPending ? 0.18 : 1
            )
                .frame(width: HUDLayout.activeWidth, height: HUDLayout.capsuleHeight)
                .background(HUDCapsuleBackground())
                .clipShape(Capsule())
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HUDThinkingPreview: View {
    var body: some View {
        HUDThinkingContent()
            .frame(width: HUDLayout.activeWidth, height: HUDLayout.capsuleHeight)
            .background(HUDCapsuleBackground())
            .clipShape(Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct HUDThinkingContent: View {
    var body: some View {
        ThinkingShimmerView()
            .padding(.vertical, HUDLayout.compactVerticalPadding)
            .padding(.horizontal, HUDLayout.regularHorizontalPadding)
    }
}

private struct HUDRecordingContent: View {
    let barHeights: [CGFloat]
    var signalMissing = false
    var controlsOpacity: Double = 1
    var waveformOpacity: Double = 1
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}

    var body: some View {
        HStack(spacing: HUDLayout.recordingSpacing) {
            hudButton(icon: "x", isConfirm: false, action: onCancel)
                .opacity(controlsOpacity)
                .allowsHitTesting(controlsOpacity > 0)
                .accessibilityHidden(controlsOpacity == 0)
                .offset(x: controlsOpacity == 0 ? HUDLayout.hiddenControlOffset : -HUDLayout.visibleControlOffset)
            ZStack {
                if signalMissing {
                    Text("没收到声音").font(.system(size: HUDLayout.textSize, weight: .semibold)).fixedSize().foregroundStyle(.white)
                } else {
                    HStack(spacing: HUDLayout.waveformSpacing) {
                        ForEach(barHeights.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 999)
                                .fill(Color(nsColor: HUDLayout.waveformColor))
                                .frame(width: HUDLayout.waveformBarWidth, height: barHeights[i])
                        }
                    }
                }
            }
            .frame(width: signalMissing ? HUDLayout.missingSignalWidth : HUDLayout.waveformWidth, height: HUDLayout.capsuleHeight - HUDLayout.scaled(6))
            .clipped()
            .opacity(waveformOpacity)
            .scaleEffect(x: 1, y: 0.88 + 0.12 * waveformOpacity, anchor: .center)
            hudButton(icon: "check", isConfirm: true, action: onConfirm)
                .opacity(controlsOpacity)
                .allowsHitTesting(controlsOpacity > 0)
                .accessibilityHidden(controlsOpacity == 0)
                .offset(x: controlsOpacity == 0 ? -HUDLayout.hiddenControlOffset : HUDLayout.visibleControlOffset)
        }
        .padding(.vertical, HUDLayout.compactVerticalPadding)
        .padding(.horizontal, HUDLayout.compactHorizontalPadding)
    }

    private func hudButton(icon: String, isConfirm: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HUDIcon(type: icon).frame(width: HUDLayout.iconSize, height: HUDLayout.iconSize)
        }
        .buttonStyle(HUDButtonStyle(isConfirm: isConfirm))
        .accessibilityLabel(isConfirm ? "结束录音" : "取消录音")
        .frame(width: HUDLayout.buttonSize, height: HUDLayout.buttonSize)
    }
}

private struct HUDCapsuleBackground: View {
    var cornerRadius: CGFloat = HUDLayout.capsuleHeight / 2
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: HUDLayout.capsuleBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(nsColor: HUDLayout.capsuleInnerStrokeColor), lineWidth: HUDLayout.backgroundInnerStroke)
                }
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(nsColor: HUDLayout.capsuleOuterStrokeColor), lineWidth: HUDLayout.backgroundOuterStroke)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - HUD Button Style

private struct HUDButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isConfirm: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: HUDLayout.buttonSize, height: HUDLayout.buttonSize)
            .background(
                Circle().fill(
                    Color(
                        nsColor: isConfirm
                            ? HUDLayout.confirmButtonBackgroundColor
                            : HUDLayout.cancelButtonBackgroundColor
                    )
                )
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        Color(
                            nsColor: isConfirm
                                ? HUDLayout.confirmButtonBackgroundColor
                                : HUDLayout.cancelButtonStrokeColor
                        ),
                        lineWidth: HUDLayout.backgroundOuterStroke
                    )
            )
            .foregroundStyle(
                Color(
                    nsColor: isConfirm
                        ? HUDLayout.confirmButtonForegroundColor
                        : HUDLayout.primaryForegroundColor
                )
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - HUD SVG-style Icons

private struct HUDIcon: View {
    let type: String

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            switch type {
            case "x":
                var path = Path()
                path.move(to: CGPoint(x: s * 0.175, y: s * 0.175))
                path.addLine(to: CGPoint(x: s * 0.825, y: s * 0.825))
                path.move(to: CGPoint(x: s * 0.825, y: s * 0.175))
                path.addLine(to: CGPoint(x: s * 0.175, y: s * 0.825))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: HUDLayout.iconStroke, lineCap: .round))
            case "check":
                var path = Path()
                path.move(to: CGPoint(x: s * 0.14, y: s * 0.53))
                path.addLine(to: CGPoint(x: s * 0.38, y: s * 0.77))
                path.addLine(to: CGPoint(x: s * 0.87, y: s * 0.26))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: HUDLayout.iconStroke, lineCap: .round, lineJoin: .round))
            case "warn":
                // 光学对齐：上方竖线略短，底部点不超过竖线视觉宽度
                var path = Path()
                path.move(to: CGPoint(x: s * 0.5, y: s * 0.25))
                path.addLine(to: CGPoint(x: s * 0.5, y: s * 0.56))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: HUDLayout.iconStroke, lineCap: .round))
                let dotRadius = HUDLayout.warningDotRadius
                let dotCenter = CGPoint(x: s * 0.5, y: s * 0.765)
                context.fill(Circle().path(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)), with: .foreground)
            case "dictionary":
                let drawSize = s * HUDLayout.noticeFilledIconScale
                let inset = (s - drawSize) / 2

                func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    CGPoint(
                        x: inset + drawSize * (x / 1024),
                        y: inset + drawSize * (y / 1024)
                    )
                }

                var frontCover = Path()
                frontCover.move(to: point(110.933333, 829.44))
                frontCover.addCurve(
                    to: point(85.333333, 803.84),
                    control1: point(97.28, 829.44),
                    control2: point(85.333333, 817.493333)
                )
                frontCover.addLine(to: point(85.333333, 220.16))
                frontCover.addCurve(
                    to: point(245.76, 59.733333),
                    control1: point(85.333333, 131.413333),
                    control2: point(157.013333, 59.733333)
                )
                frontCover.addLine(to: point(738.986667, 59.733333))
                frontCover.addCurve(
                    to: point(764.586667, 85.333333),
                    control1: point(752.64, 59.733333),
                    control2: point(764.586667, 71.68)
                )
                frontCover.addLine(to: point(764.586667, 669.013333))
                frontCover.addCurve(
                    to: point(738.986667, 694.613333),
                    control1: point(764.586667, 682.666667),
                    control2: point(752.64, 694.613333)
                )
                frontCover.addLine(to: point(245.76, 694.613333))
                frontCover.addCurve(
                    to: point(136.533333, 803.84),
                    control1: point(186.026667, 694.613333),
                    control2: point(136.533333, 744.106667)
                )
                frontCover.addCurve(
                    to: point(110.933333, 829.44),
                    control1: point(136.533333, 817.493333),
                    control2: point(126.293333, 829.44)
                )
                frontCover.closeSubpath()

                frontCover.move(to: point(245.76, 110.933333))
                frontCover.addCurve(
                    to: point(136.533333, 220.16),
                    control1: point(186.026667, 110.933333),
                    control2: point(136.533333, 160.426667)
                )
                frontCover.addLine(to: point(136.533333, 686.08))
                frontCover.addCurve(
                    to: point(245.76, 643.413333),
                    control1: point(165.546667, 658.773333),
                    control2: point(203.093333, 643.413333)
                )
                frontCover.addLine(to: point(713.386667, 643.413333))
                frontCover.addLine(to: point(713.386667, 110.933333))
                frontCover.addLine(to: point(245.76, 110.933333))
                frontCover.closeSubpath()
                context.fill(frontCover, with: .foreground, style: FillStyle(eoFill: true))

                var pageBlock = Path()
                pageBlock.move(to: point(875.52, 964.266667))
                pageBlock.addLine(to: point(245.76, 964.266667))
                pageBlock.addCurve(
                    to: point(85.333333, 803.84),
                    control1: point(157.013333, 964.266667),
                    control2: point(85.333333, 892.586667)
                )
                pageBlock.addCurve(
                    to: point(245.76, 643.413333),
                    control1: point(85.333333, 715.093333),
                    control2: point(157.013333, 643.413333)
                )
                pageBlock.addLine(to: point(738.986667, 643.413333))
                pageBlock.addCurve(
                    to: point(764.586667, 669.013333),
                    control1: point(752.64, 643.413333),
                    control2: point(764.586667, 655.36)
                )
                pageBlock.addCurve(
                    to: point(738.986667, 694.613333),
                    control1: point(764.586667, 682.666667),
                    control2: point(752.64, 694.613333)
                )
                pageBlock.addLine(to: point(245.76, 694.613333))
                pageBlock.addCurve(
                    to: point(136.533333, 803.84),
                    control1: point(186.026667, 694.613333),
                    control2: point(136.533333, 744.106667)
                )
                pageBlock.addCurve(
                    to: point(245.76, 913.066667),
                    control1: point(136.533333, 863.573333),
                    control2: point(186.026667, 913.066667)
                )
                pageBlock.addLine(to: point(848.213333, 913.066667))
                pageBlock.addLine(to: point(848.213333, 129.706667))
                pageBlock.addCurve(
                    to: point(873.813333, 104.106667),
                    control1: point(848.213333, 116.053333),
                    control2: point(860.16, 104.106667)
                )
                pageBlock.addCurve(
                    to: point(899.413333, 129.706667),
                    control1: point(887.466667, 104.106667),
                    control2: point(899.413333, 116.053333)
                )
                pageBlock.addLine(to: point(899.413333, 938.666667))
                pageBlock.addCurve(
                    to: point(875.52, 964.266667),
                    control1: point(901.12, 952.32),
                    control2: point(889.173333, 964.266667)
                )
                pageBlock.closeSubpath()
                context.fill(pageBlock, with: .foreground)

                var bottomRule = Path()
                bottomRule.move(to: point(718.506667, 829.44))
                bottomRule.addLine(to: point(269.653333, 829.44))
                bottomRule.addCurve(
                    to: point(244.053333, 803.84),
                    control1: point(256, 829.44),
                    control2: point(244.053333, 817.493333)
                )
                bottomRule.addCurve(
                    to: point(269.653333, 778.24),
                    control1: point(244.053333, 790.186667),
                    control2: point(256, 778.24)
                )
                bottomRule.addLine(to: point(718.506667, 778.24))
                bottomRule.addCurve(
                    to: point(744.106667, 803.84),
                    control1: point(732.16, 778.24),
                    control2: point(744.106667, 790.186667)
                )
                bottomRule.addCurve(
                    to: point(718.506667, 829.44),
                    control1: point(744.106667, 817.493333),
                    control2: point(732.16, 829.44)
                )
                bottomRule.closeSubpath()
                context.fill(bottomRule, with: .foreground)
            default:
                break
            }
        }
    }
}

// MARK: - Thinking Shimmer

private struct ThinkingShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.775 : context.date.timeIntervalSinceReferenceDate
            let cycle = 1.55
            let phase = time.truncatingRemainder(dividingBy: cycle) / cycle
            // center 从 -0.6 扫到 1.6（从左往右），复刻原型 CSS shimmer
            let center = -0.6 + phase * 2.2

            ZStack {
                thinkingText
                    .foregroundStyle(Color(nsColor: HUDLayout.thinkingBaseTextColor))

                thinkingText
                    .foregroundStyle(Color(nsColor: HUDLayout.thinkingHighlightTextColor))
                    .mask {
                        GeometryReader { geo in
                            let w = geo.size.width
                            let gradWidth = w * 2.2
                            let offset = center * w - gradWidth / 2 + w / 2
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.3),
                                    .init(color: .white, location: 0.48),
                                    .init(color: .clear, location: 0.7),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: gradWidth)
                            .offset(x: offset)
                        }
                    }
            }
        }
    }

    private var thinkingText: some View {
        Text("THINKING")
            .font(.system(size: HUDLayout.textSize, weight: .semibold))
            .tracking(HUDLayout.thinkingTracking)
    }
}
