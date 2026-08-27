import Foundation

nonisolated enum CodexWindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case weekly
    case other

    var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "7d"
        case .other: "—"
        }
    }

    var title: String {
        switch self {
        case .fiveHour: "5 小时"
        case .weekly: "每周"
        case .other: "额度"
        }
    }
}

nonisolated struct CodexUsageWindow: Codable, Equatable, Identifiable, Sendable {
    let kind: CodexWindowKind
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var id: CodexWindowKind { kind }
    var remainingPercent: Int { min(100, max(0, 100 - usedPercent)) }
    var remainingFraction: Double { Double(remainingPercent) / 100 }
}

nonisolated struct CodexResetCredit: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String?
    let status: String
    let expiresAt: Date?

    var displayTitle: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Full Reset"
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Full Reset") == .orderedSame {
            return "Full Reset"
        }
        return title
    }
}

nonisolated struct CodexResetCreditsSummary: Codable, Equatable, Sendable {
    let availableCount: Int
    let credits: [CodexResetCredit]?

    var availableCredits: [CodexResetCredit] {
        (credits ?? [])
            .filter { $0.status == "available" }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?): lhsDate < rhsDate
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.id < rhs.id
                }
            }
    }

    var nearestExpiration: Date? {
        availableCredits.compactMap(\.expiresAt).min()
    }
}

nonisolated enum CodexResetExpirationFormat {
    static func monthDay(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month(.defaultDigits)
                .day()
                .locale(Locale(identifier: "zh_CN"))
        )
    }
}

nonisolated enum CodexRecoveryFormat {
    static func remaining(until date: Date, relativeTo referenceDate: Date = .now) -> String {
        let totalMinutes = max(0, Int(ceil(date.timeIntervalSince(referenceDate) / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes / 60 % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)天\(hours)小时\(minutes)分钟"
        }
        if hours > 0 {
            return "\(hours)小时\(minutes)分钟"
        }
        return "\(minutes)分钟"
    }

    static func date(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month()
                .day()
                .hour()
                .minute()
                .locale(Locale(identifier: "zh_CN"))
        )
    }
}

nonisolated enum CodexSnapshotSource: String, Codable, Sendable {
    case appServer
    case sessionLog
    case mac
    case preview
}

nonisolated struct CodexStatusSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let windows: [CodexUsageWindow]
    let planName: String?
    let creditsBalance: String?
    let resetCredits: CodexResetCreditsSummary?
    let capturedAt: Date
    let source: CodexSnapshotSource

    init(
        windows: [CodexUsageWindow],
        planName: String?,
        creditsBalance: String? = nil,
        resetCredits: CodexResetCreditsSummary? = nil,
        capturedAt: Date = .now,
        source: CodexSnapshotSource
    ) {
        self.schemaVersion = Self.schemaVersion
        self.windows = windows.sorted { lhs, rhs in
            Self.sortIndex(lhs.kind) < Self.sortIndex(rhs.kind)
        }
        self.planName = planName
        self.creditsBalance = creditsBalance
        self.resetCredits = resetCredits
        self.capturedAt = capturedAt
        self.source = source
    }

    var isStale: Bool { Date.now.timeIntervalSince(capturedAt) > 20 * 60 }
    var fiveHour: CodexUsageWindow? { windows.first { $0.kind == .fiveHour } }
    var weekly: CodexUsageWindow? { windows.first { $0.kind == .weekly } }

    var integerCreditsBalance: String? {
        guard let creditsBalance else { return nil }
        let trimmedBalance = creditsBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBalance.isEmpty else { return nil }
        guard var decimalBalance = Decimal(
            string: trimmedBalance,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            return trimmedBalance
        }

        var roundedBalance = Decimal()
        NSDecimalRound(&roundedBalance, &decimalBalance, 0, .plain)
        return NSDecimalNumber(decimal: roundedBalance).stringValue
    }

    func receivedFromMac() -> CodexStatusSnapshot {
        CodexStatusSnapshot(
            windows: windows,
            planName: planName,
            creditsBalance: creditsBalance,
            resetCredits: resetCredits,
            capturedAt: capturedAt,
            source: .mac
        )
    }

    static let preview = CodexStatusSnapshot(
        windows: [
            CodexUsageWindow(
                kind: .fiveHour,
                usedPercent: 27,
                durationMinutes: 300,
                resetsAt: .now.addingTimeInterval(3.5 * 3600)
            ),
            CodexUsageWindow(
                kind: .weekly,
                usedPercent: 42,
                durationMinutes: 10_080,
                resetsAt: .now.addingTimeInterval(4 * 86_400)
            )
        ],
        planName: "Plus",
        resetCredits: CodexResetCreditsSummary(
            availableCount: 2,
            credits: [
                CodexResetCredit(
                    id: "preview-reset-1",
                    title: "Full Reset",
                    status: "available",
                    expiresAt: .now.addingTimeInterval(25 * 86_400)
                ),
                CodexResetCredit(
                    id: "preview-reset-2",
                    title: nil,
                    status: "available",
                    expiresAt: .now.addingTimeInterval(40 * 86_400)
                )
            ]
        ),
        source: .preview
    )

    static func kind(forDuration minutes: Int?, fallbackIndex: Int) -> CodexWindowKind {
        guard let minutes else { return fallbackIndex == 0 ? .fiveHour : .weekly }
        if (240 ... 360).contains(minutes) { return .fiveHour }
        if (9_000 ... 11_000).contains(minutes) { return .weekly }
        return .other
    }

    private static func sortIndex(_ kind: CodexWindowKind) -> Int {
        switch kind {
        case .fiveHour: 0
        case .weekly: 1
        case .other: 2
        }
    }
}

nonisolated struct MacConnection: Codable, Equatable, Sendable {
    let baseURL: URL
    let accessToken: String

    var pairingURL: URL? {
        var components = URLComponents()
        components.scheme = "codexbuddynew"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "url", value: baseURL.absoluteString),
            URLQueryItem(name: "token", value: accessToken)
        ]
        return components.url
    }

    init(baseURL: URL, accessToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    init?(pairingURL: URL) {
        guard pairingURL.scheme == "codexbuddynew",
              pairingURL.host == "pair",
              let components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false),
              let urlText = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let baseURL = URL(string: urlText),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return nil }
        self.init(baseURL: baseURL, accessToken: token)
    }
}

nonisolated enum CodexHealthLevel: Sendable {
    case good
    case attention
    case low

    init(remainingPercent: Int) {
        if remainingPercent > 60 {
            self = .good
        } else if remainingPercent >= 20 {
            self = .attention
        } else {
            self = .low
        }
    }
}
