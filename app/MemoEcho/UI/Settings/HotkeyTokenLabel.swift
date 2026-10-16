import SwiftUI

/// Inline symbols share the text baseline and spacing at every keycap size.
struct HotkeyTokenLabel: View {
    let token: HotkeyToken

    var body: some View {
        label
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel(token.accessibilityLabel)
    }

    private var label: Text {
        if let systemImage = token.trailingSystemImage {
            Text("\(token.visualLabel) / \(Image(systemName: systemImage))")
        } else {
            Text(token.visualLabel)
        }
    }
}
