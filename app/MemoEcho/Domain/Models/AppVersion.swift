import Foundation

struct AppVersion: Comparable, Sendable {
    let rawValue: String
    private let numericComponents: [Int]
    private let betaNumber: Int?

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let versionParts = normalized.components(separatedBy: "-beta.")
        guard versionParts.count <= 2 else { return nil }
        if versionParts.count == 2 {
            let suffix = versionParts[1]
            guard suffix.first != "0",
                  suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(suffix), (1...255).contains(number) else { return nil }
            betaNumber = number
        } else {
            betaNumber = nil
        }
        let pieces = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }

        var parsedComponents: [Int] = []
        parsedComponents.reserveCapacity(pieces.count)

        for piece in pieces {
            guard let value = Int(piece), value >= 0 else { return nil }
            parsedComponents.append(value)
        }

        self.rawValue = normalized
        numericComponents = parsedComponents
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        let maxCount = max(lhs.numericComponents.count, rhs.numericComponents.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
            let rhsValue = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0

            if lhsValue != rhsValue {
                return lhsValue < rhsValue ? -1 : 1
            }
        }

        switch (lhs.betaNumber, rhs.betaNumber) {
        case let (left?, right?):
            return left == right ? 0 : (left < right ? -1 : 1)
        case (_?, nil):
            return -1
        case (nil, _?):
            return 1
        case (nil, nil):
            return 0
        }
    }

    static func current(in bundle: Bundle = .main) -> AppVersion? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(version)
    }
}
