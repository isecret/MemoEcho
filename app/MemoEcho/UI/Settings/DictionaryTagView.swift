import AppKit
import SwiftUI

struct DictionaryTagView: View {
    let term: String
    let isAutoLearned: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(term)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isAutoLearned {
                    Circle().fill(.blue).frame(width: 5, height: 5)
                        .fixedSize()
                        .help("自动学习")
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .overlay {
                DictionaryTagClickTarget(onSelect: onSelect, onEdit: onEdit)
                    .accessibilityHidden(true)
            }
            .help(term)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(term)
            .accessibilityValue(isAutoLearned ? "自动学习" : "手动添加")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityAction { onEdit() }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .padding(.trailing, 4)
            .help("删除词条")
            .accessibilityLabel("删除\(term)")
        }
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(isHovered ? 0.08 : 0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("编辑", action: onEdit)
            Button("删除", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Handle selection directly rather than waiting for a single/double tap recognizer pair.
private struct DictionaryTagClickTarget: NSViewRepresentable {
    let onSelect: () -> Void
    let onEdit: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onSelect = onSelect
        view.onEdit = onEdit
    }

    final class ClickView: NSView {
        var onSelect: () -> Void = {}
        var onEdit: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onSelect()
        }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2, bounds.contains(convert(event.locationInWindow, from: nil)) {
                onEdit()
            }
        }
    }
}
