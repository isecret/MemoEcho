import Foundation

enum HotkeyTriggerMode: String, Codable, CaseIterable, Sendable {
    case singlePress, doublePress, hold

    var title: String {
        switch self {
        case .singlePress: "单按"
        case .doublePress: "双按"
        case .hold: "按住"
        }
    }

    var instruction: String {
        switch self {
        case .singlePress: "按一下开始，再按一下结束。"
        case .doublePress: "连按两下开始，再连按两下结束。"
        case .hold: "按住说话，松开提交。"
        }
    }

    func startInstruction(key: String) -> String {
        switch self {
        case .singlePress: "按下快捷键 \(key)，开始说话…"
        case .doublePress: "连按两下 \(key)，开始说话…"
        case .hold: "按住 \(key)，开始说话…"
        }
    }
}
