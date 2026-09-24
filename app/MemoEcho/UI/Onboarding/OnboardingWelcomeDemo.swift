import SwiftUI

/// Product-approved illustrative copy, shared by the chat and model demos.
/// This is a fixed example, not a live model response or a user's conversation.
enum OnboardingDemoCopy {
    static let question = "关于记录灵感的工具，你有什么想法吗？"
    static let originalText = "嗯…我觉得先把分类做起来，啊不对，先把语音入口做起来吧，让记录更顺手。用户想到什么，嗯，那个，就先记录，不管是笔记、任务还是想法，都先记下来，然后至于后面怎么理解、分类和整理，呃，就是交给 AI 就好了。"
    static let reply = "我觉得先把语音入口做起来，让记录更顺手。用户想到什么就先记录，不管是笔记、任务还是想法，都先记下来，至于后面怎么理解、分类和整理，交给 AI 就好了。"
    static let deletedOriginalPhrases = ["嗯…", "先把分类做起来，啊不对，", "吧", "，嗯，那个，", "然后", "呃，就是"]

    static var originalAccessibilityLabel: String {
        let deletions = deletedOriginalPhrases.map { "“\($0)”" }.joined(separator: "、")
        return "原始转写：\(originalText)已划去改口前的内容和口头赘词：\(deletions)。润色结果保留改口后的想法。"
    }

    static var highlightedOriginalText: AttributedString {
        var text = AttributedString(originalText)
        for phrase in deletedOriginalPhrases {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text[searchStart...].range(of: phrase) {
                text[range].strikethroughStyle = .single
                text[range].foregroundColor = .red
                text[range].backgroundColor = Color.red.opacity(0.08)
                searchStart = range.upperBound
            }
        }
        return text
    }

    static var highlightedReply: AttributedString {
        var text = AttributedString(reply)
        if let range = text.range(of: "先把语音入口做起来") {
            text[range].foregroundColor = .accentColor
            text[range].backgroundColor = Color.accentColor.opacity(0.14)
        }
        return text
    }
}

/// An illustration only: it never starts a session, captures audio, or sends text.
struct OnboardingWelcomeDemo: View {
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cycleStart = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion || !isActive)) { context in
            OnboardingWelcomeScene(phase: reduceMotion
                ? .filled
                : OnboardingWelcomePhase.at(isActive ? context.date.timeIntervalSince(cycleStart) : 0))
        }
        .onAppear { cycleStart = Date() }
        .onChange(of: isActive) { if isActive { cycleStart = Date() } }
    }
}

enum OnboardingWelcomePhase: CaseIterable, Equatable {
    case waiting, pending, recording, thinking, filled

    static func at(_ elapsed: TimeInterval) -> Self {
        let time = max(0, elapsed).truncatingRemainder(dividingBy: 9)
        switch time {
        case ..<0.6: return .waiting
        case ..<1.2: return .pending
        case ..<4: return .recording
        case ..<5.6: return .thinking
        default: return .filled
        }
    }
}

struct OnboardingWelcomeScene: View {
    let phase: OnboardingWelcomePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            conversation
            composer
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: 550, height: 326)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(cardShape)
        .overlay {
            cardShape
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("朋友问：\(OnboardingDemoCopy.question)语音回复演示：开始录音，等待处理，再把“\(OnboardingDemoCopy.reply)”填入聊天框。")
    }

    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
    }

    private var contactAvatar: some View {
        Image("OnboardingAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var conversation: some View {
        HStack(alignment: .top, spacing: 10) {
            contactAvatar
            Text(OnboardingDemoCopy.question)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 132)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text("说说你的想法…")
                    .foregroundStyle(.tertiary)
                    .opacity(phase == .filled ? 0 : 1)
                Text(OnboardingDemoCopy.reply)
                    .foregroundStyle(.primary)
                    .opacity(phase == .filled ? 1 : 0)
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 15) {
                ForEach(["face.smiling", "folder", "scissors", "mic"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .regular))
                }
                .foregroundStyle(.secondary)
                Spacer()
                Text("发送")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(phase == .filled ? Color.accentColor : Color.secondary.opacity(0.6))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 7)
                    .background(phase == .filled ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(16)
        .frame(height: 184)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            // Overlay never contributes to the composer size. An EmptyView
            // with a frame in the old VStack still collapsed between stages.
            ZStack { previewHUD }
                .frame(width: HUDLayout.activeWidth, height: HUDLayout.capsuleHeight)
                .padding(.bottom, 46)
        }
    }

    @ViewBuilder
    private var previewHUD: some View {
        switch phase {
        case .waiting, .filled:
            EmptyView()
        case .pending:
            HUDRecordingPreview(reduceMotion: true, isPending: true)
        case .recording:
            HUDRecordingPreview(reduceMotion: reduceMotion)
        case .thinking:
            HUDThinkingPreview()
        }
    }
}
