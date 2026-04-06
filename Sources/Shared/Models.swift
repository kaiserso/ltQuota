import Foundation

// MARK: - Policy

/// Per-child-user enforcement policy, stored as JSON under
/// /Library/Application Support/LocalTimeQuota/policies/<username>.json
public struct UserPolicy: Codable, Sendable {
    public var version: Int
    public var username: String
    public var enabled: Bool
    /// Total allowed active time per calendar day, in seconds.
    public var dailyLimitSeconds: Int
    /// If false, idle time is not counted against the quota.
    public var countIdleTime: Bool
    /// Seconds of inactivity before the session is considered idle.
    public var idleThresholdSeconds: Int
    /// Warning-countdown duration before forced logout/lock.
    public var gracePeriodSeconds: Int
    /// Enforcement action once quota is exhausted.
    public var enforcementMode: EnforcementMode
    /// How many seconds before zero to show an early warning banner.
    public var warningThresholdSeconds: Int
    /// Whether parent override commands (bonus, reset) are allowed.
    public var allowParentOverride: Bool

    public init(
        version: Int = 1,
        username: String,
        enabled: Bool = true,
        dailyLimitSeconds: Int = 7200,
        countIdleTime: Bool = false,
        idleThresholdSeconds: Int = 300,
        gracePeriodSeconds: Int = 60,
        enforcementMode: EnforcementMode = .logout,
        warningThresholdSeconds: Int = 300,
        allowParentOverride: Bool = true
    ) {
        self.version = version
        self.username = username
        self.enabled = enabled
        self.dailyLimitSeconds = dailyLimitSeconds
        self.countIdleTime = countIdleTime
        self.idleThresholdSeconds = idleThresholdSeconds
        self.gracePeriodSeconds = gracePeriodSeconds
        self.enforcementMode = enforcementMode
        self.warningThresholdSeconds = warningThresholdSeconds
        self.allowParentOverride = allowParentOverride
    }

    enum CodingKeys: String, CodingKey {
        case version
        case username
        case enabled
        case dailyLimitSeconds       = "daily_limit_seconds"
        case countIdleTime           = "count_idle_time"
        case idleThresholdSeconds    = "idle_threshold_seconds"
        case gracePeriodSeconds      = "grace_period_seconds"
        case enforcementMode         = "enforcement_mode"
        case warningThresholdSeconds = "warning_threshold_seconds"
        case allowParentOverride     = "allow_parent_override"
    }
}

public enum EnforcementMode: String, Codable, Sendable {
    case logout
    case lock
}

// MARK: - Usage Ledger

/// Daily usage ledger, stored as JSON under
/// /Library/Application Support/LocalTimeQuota/usage/<username>/<YYYY-MM-DD>.json
public struct UsageLedger: Codable, Sendable {
    public var version: Int
    public var username: String
    /// ISO-8601 date string: "YYYY-MM-DD"
    public var date: String
    /// Authoritative cumulative active seconds used today.
    public var countedSeconds: Int
    /// True once the day's quota has been fully consumed.
    public var exhausted: Bool
    /// True once the early-warning banner has been shown.
    public var warningIssued: Bool
    /// Wall-clock ISO-8601 timestamp when the final grace countdown began; nil if not started.
    public var graceStartedAt: String?
    /// Monotonic time of the last update (seconds since boot).
    public var lastUpdateMonotonic: Double
    /// Wall-clock ISO-8601 timestamp of the last update.
    public var lastUpdateWallclock: String
    /// Session ID of the agent that performed the last update.
    public var lastAgentBootSessionId: String?
    /// Audit event log (kept compact; cap in daemon as needed).
    public var events: [LedgerEvent]

    public init(
        version: Int = 1,
        username: String,
        date: String,
        countedSeconds: Int = 0,
        exhausted: Bool = false,
        warningIssued: Bool = false,
        graceStartedAt: String? = nil,
        lastUpdateMonotonic: Double = 0,
        lastUpdateWallclock: String = "",
        lastAgentBootSessionId: String? = nil,
        events: [LedgerEvent] = []
    ) {
        self.version = version
        self.username = username
        self.date = date
        self.countedSeconds = countedSeconds
        self.exhausted = exhausted
        self.warningIssued = warningIssued
        self.graceStartedAt = graceStartedAt
        self.lastUpdateMonotonic = lastUpdateMonotonic
        self.lastUpdateWallclock = lastUpdateWallclock
        self.lastAgentBootSessionId = lastAgentBootSessionId
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case version
        case username
        case date
        case countedSeconds          = "counted_seconds"
        case exhausted
        case warningIssued           = "warning_issued"
        case graceStartedAt          = "grace_started_at"
        case lastUpdateMonotonic     = "last_update_monotonic"
        case lastUpdateWallclock     = "last_update_wallclock"
        case lastAgentBootSessionId  = "last_agent_boot_session_id"
        case events
    }
}

public struct LedgerEvent: Codable, Sendable {
    public var ts: String
    public var type: String
    public var note: String?

    public init(ts: String, type: String, note: String? = nil) {
        self.ts = ts
        self.type = type
        self.note = note
    }
}

// MARK: - Daemon Status (returned to callers)

/// Current status snapshot returned by GetStatus and AddUsage.
public struct DaemonStatus: Codable, Sendable {
    public var username: String
    public var enabled: Bool
    public var dailyLimitSeconds: Int
    public var countedSeconds: Int
    public var remainingSeconds: Int
    public var exhausted: Bool
    public var currentDate: String
    public var gracePeriodSeconds: Int
    public var enforcementMode: EnforcementMode
    public var graceStartedAt: String?
    public var warningThresholdSeconds: Int

    public init(
        username: String,
        enabled: Bool,
        dailyLimitSeconds: Int,
        countedSeconds: Int,
        remainingSeconds: Int,
        exhausted: Bool,
        currentDate: String,
        gracePeriodSeconds: Int,
        enforcementMode: EnforcementMode,
        graceStartedAt: String? = nil,
        warningThresholdSeconds: Int
    ) {
        self.username = username
        self.enabled = enabled
        self.dailyLimitSeconds = dailyLimitSeconds
        self.countedSeconds = countedSeconds
        self.remainingSeconds = remainingSeconds
        self.exhausted = exhausted
        self.currentDate = currentDate
        self.gracePeriodSeconds = gracePeriodSeconds
        self.enforcementMode = enforcementMode
        self.graceStartedAt = graceStartedAt
        self.warningThresholdSeconds = warningThresholdSeconds
    }

    enum CodingKeys: String, CodingKey {
        case username
        case enabled
        case dailyLimitSeconds       = "daily_limit_seconds"
        case countedSeconds          = "counted_seconds"
        case remainingSeconds        = "remaining_seconds"
        case exhausted
        case currentDate             = "current_date"
        case gracePeriodSeconds      = "grace_period_seconds"
        case enforcementMode         = "enforcement_mode"
        case graceStartedAt          = "grace_started_at"
        case warningThresholdSeconds = "warning_threshold_seconds"
    }
}

// MARK: - IPC Message Types (XPC payload wrappers)

/// Sent by agent on every tick.
public struct AddUsageRequest: Codable, Sendable {
    public var username: String
    public var date: String
    public var activeDeltaSeconds: Int
    public var idleDeltaSeconds: Int
    public var sessionId: String
    public var tickSeq: Int

    public init(
        username: String,
        date: String,
        activeDeltaSeconds: Int,
        idleDeltaSeconds: Int,
        sessionId: String,
        tickSeq: Int
    ) {
        self.username = username
        self.date = date
        self.activeDeltaSeconds = activeDeltaSeconds
        self.idleDeltaSeconds = idleDeltaSeconds
        self.sessionId = sessionId
        self.tickSeq = tickSeq
    }

    enum CodingKeys: String, CodingKey {
        case username
        case date
        case activeDeltaSeconds  = "active_delta_seconds"
        case idleDeltaSeconds    = "idle_delta_seconds"
        case sessionId           = "session_id"
        case tickSeq             = "tick_seq"
    }
}

/// Generic IPC result wrapping an optional payload and an optional error string.
public struct IPCResult<T: Codable & Sendable>: Codable, Sendable {
    public var success: Bool
    public var error: String?
    public var payload: T?

    public init(success: Bool, error: String? = nil, payload: T? = nil) {
        self.success = success
        self.error = error
        self.payload = payload
    }
}

// MARK: - Date helpers

public enum DateHelper {
    private static let localDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Intentionally uses local timezone — this is the authoritative day boundary.
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "YYYY-MM-DD" in local timezone.
    public static func localDateString(from date: Date = Date()) -> String {
        localDateFormatter.string(from: date)
    }

    /// Current ISO-8601 wall-clock timestamp for logs.
    public static func isoNow() -> String {
        isoFormatter.string(from: Date())
    }

    /// Seconds until next local midnight from `date`.
    public static func secondsUntilMidnight(from date: Date = Date()) -> TimeInterval {
        let calendar = Calendar.current
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: date)!)
        return tomorrow.timeIntervalSince(date)
    }
}

// MARK: - Monotonic clock

public enum MonotonicClock {
    /// Current monotonic time in seconds (CLOCK_MONOTONIC_RAW).
    public static func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}
