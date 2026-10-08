import SwiftUI

struct HotkeyTriggerModePicker: View {
    let hotkey: HotkeyCombo
    var onCommit: (HotkeyCombo) -> Bool
    var isEnabled = true
    var alignment: Alignment = .center

    var body: some View {
        Picker("录音方式", selection: Binding(
            get: { hotkey.triggerMode },
            set: { _ = onCommit(hotkey.withTriggerMode($0)) }
        )) {
            ForEach(HotkeyTriggerMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode).help(mode.instruction)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240, alignment: alignment)
        .disabled(!isEnabled)
        .accessibilityLabel("录音方式")
        .accessibilityValue(hotkey.triggerMode.title)
        .accessibilityHint(hotkey.triggerMode.instruction)
    }
}
