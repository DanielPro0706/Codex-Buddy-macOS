import Foundation

/// Activity in the selected local Codex home. Unknown must never be treated as idle.
nonisolated enum MacCodexActivity: Equatable, Sendable {
    case active
    case inactive
    case unknown
}

nonisolated struct MacRefreshEnvironment: Equatable, Sendable {
    var allDisplaysAsleep: Bool
    var activity: MacCodexActivity
    var isOnACPower = true
    var isPowerSourceKnown = true
    var lidClosed = false
    var hasExternalDisplay = true
    var isScreenLocked = false
    var isScreenSaverRunning = false
    var allExternalDisplaysAsleep = false

    static let unknown = Self(allDisplaysAsleep: false, activity: .unknown, isPowerSourceKnown: false)

    var permitsIdleBackoff: Bool {
        isIdleEligible && activity == .inactive
    }

    var isIdleEligible: Bool {
        allDisplaysAsleep || (lidClosed && (
            !hasExternalDisplay || isScreenLocked || isScreenSaverRunning || allExternalDisplaysAsleep
        ))
    }
}

/// The first idle interval is a confirmation period, not evidence of inactivity.
nonisolated struct MacRefreshPolicy: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case normal
        case initialIdle
        case extendedIdle
    }

    static let normalInterval: Duration = .seconds(15)
    static let batteryNormalInterval: Duration = .seconds(30)
    static let initialIdleInterval: Duration = .seconds(30 * 60)
    static let extendedIdleInterval: Duration = .seconds(60 * 60)

    private(set) var environment: MacRefreshEnvironment
    private(set) var phase: Phase = .normal
    private var firstIdleCheckAt: Date?

    init(environment: MacRefreshEnvironment = .unknown, now: Date = .now) {
        self.environment = environment
        update(environment: environment, now: now)
    }

    var interval: Duration {
        switch phase {
        case .normal:
            environment.isPowerSourceKnown && environment.isOnACPower
                ? Self.normalInterval : Self.batteryNormalInterval
        case .initialIdle: Self.initialIdleInterval
        case .extendedIdle: Self.extendedIdleInterval
        }
    }

    /// Returns whether the scheduling inputs changed. Repeated idle observations
    /// preserve the existing 30-minute deadline.
    @discardableResult
    mutating func update(environment: MacRefreshEnvironment, now: Date = .now) -> Bool {
        let previousEnvironment = self.environment
        let previousPhase = phase
        self.environment = environment
        if !environment.permitsIdleBackoff {
            phase = .normal
            firstIdleCheckAt = nil
        } else if phase == .normal {
            phase = .initialIdle
            firstIdleCheckAt = now.addingTimeInterval(30 * 60)
        }
        return previousEnvironment != environment || previousPhase != phase
    }

    /// Call only for a scheduled environment check. Manual refreshes and ordinary
    /// file notifications must not promote the idle schedule.
    mutating func didPerformScheduledCheck(
        environment: MacRefreshEnvironment,
        now: Date = .now
    ) {
        update(environment: environment, now: now)
        if phase == .initialIdle,
           let firstIdleCheckAt,
           now >= firstIdleCheckAt {
            phase = .extendedIdle
        }
    }

    func nextDelay(now: Date = .now) -> Duration {
        guard phase == .initialIdle, let firstIdleCheckAt else { return interval }
        // A backward wall-clock adjustment must not create a longer first interval.
        return .seconds(max(0, min(30 * 60, firstIdleCheckAt.timeIntervalSince(now))))
    }
}
