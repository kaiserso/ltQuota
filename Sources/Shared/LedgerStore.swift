import Foundation

// MARK: - Storage paths

public enum StoragePaths {
    public static let root      = "/Library/Application Support/LocalTimeQuota"
    public static let policies  = root + "/policies"
    public static let usage     = root + "/usage"
    public static let logs      = root + "/logs"
    public static let state     = root + "/state"

    public static func policyPath(for username: String) -> String {
        policies + "/\(username).json"
    }

    public static func usageDir(for username: String) -> String {
        usage + "/\(username)"
    }

    public static func ledgerPath(for username: String, date: String) -> String {
        usageDir(for: username) + "/\(date).json"
    }
}

// MARK: - LedgerStore errors

public enum LedgerStoreError: Error, CustomStringConvertible, Sendable {
    case notFound(String)
    case invalidData(String)
    case writeFailure(String)
    case validationFailure(String)

    public var description: String {
        switch self {
        case .notFound(let m):          return "Not found: \(m)"
        case .invalidData(let m):       return "Invalid data: \(m)"
        case .writeFailure(let m):      return "Write failure: \(m)"
        case .validationFailure(let m): return "Validation failure: \(m)"
        }
    }
}

// MARK: - LedgerStore

/// Provides atomic read/write access to policy and usage-ledger JSON files.
/// All file I/O is synchronous and should be called from a serial queue in the daemon.
public struct LedgerStore: Sendable {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    // MARK: Policy

    /// Load and validate a policy file. Returns nil if the file does not exist.
    /// Throws LedgerStoreError.validationFailure if the file exists but is corrupt/invalid.
    public static func loadPolicy(for username: String) throws -> UserPolicy? {
        let path = StoragePaths.policyPath(for: username)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw LedgerStoreError.invalidData("Cannot read policy at \(path): \(error)")
        }

        let policy: UserPolicy
        do {
            policy = try decoder.decode(UserPolicy.self, from: data)
        } catch {
            throw LedgerStoreError.validationFailure("Cannot parse policy at \(path): \(error)")
        }

        // Sanity checks
        guard policy.username == username else {
            throw LedgerStoreError.validationFailure(
                "Policy username '\(policy.username)' does not match path username '\(username)'"
            )
        }
        guard policy.dailyLimitSeconds > 0 else {
            throw LedgerStoreError.validationFailure(
                "daily_limit_seconds must be positive, got \(policy.dailyLimitSeconds)"
            )
        }
        guard policy.idleThresholdSeconds >= 0 else {
            throw LedgerStoreError.validationFailure(
                "idle_threshold_seconds must be non-negative"
            )
        }

        return policy
    }

    /// Atomically write a policy file.
    public static func savePolicy(_ policy: UserPolicy) throws {
        let path = StoragePaths.policyPath(for: policy.username)
        try ensureDirectory(StoragePaths.policies)
        let data = try encoder.encode(policy)
        try atomicWrite(data: data, to: path)
    }

    // MARK: Ledger

    /// Load and validate a usage ledger for (username, date).
    /// Returns nil if no ledger exists yet for that day.
    /// Throws LedgerStoreError.validationFailure if the file exists but is corrupt.
    public static func loadLedger(for username: String, date: String) throws -> UsageLedger? {
        let path = StoragePaths.ledgerPath(for: username, date: date)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw LedgerStoreError.invalidData("Cannot read ledger at \(path): \(error)")
        }

        let ledger: UsageLedger
        do {
            ledger = try decoder.decode(UsageLedger.self, from: data)
        } catch {
            throw LedgerStoreError.validationFailure("Cannot parse ledger at \(path): \(error)")
        }

        try validateLedger(ledger, expectedUsername: username, expectedDate: date)
        return ledger
    }

    /// Atomically write a usage ledger.
    public static func saveLedger(_ ledger: UsageLedger) throws {
        let dir = StoragePaths.usageDir(for: ledger.username)
        try ensureDirectory(dir)
        let path = StoragePaths.ledgerPath(for: ledger.username, date: ledger.date)
        let data = try encoder.encode(ledger)
        try atomicWrite(data: data, to: path)
    }

    // MARK: Managed users

    /// Returns all usernames that have a policy file.
    public static func listManagedUsers() -> [String] {
        let dir = StoragePaths.policies
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return items
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    // MARK: - Internal helpers

    /// Write data atomically: write to a .tmp file then rename over the target.
    static func atomicWrite(data: Data, to path: String) throws {
        let tmpPath = path + ".tmp"
        let url = URL(fileURLWithPath: path)
        let tmpURL = URL(fileURLWithPath: tmpPath)

        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            throw LedgerStoreError.writeFailure("Cannot write tmp file \(tmpPath): \(error)")
        }

        do {
            // rename(2) is atomic on the same filesystem.
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
        } catch {
            // Clean up orphaned tmp on failure.
            try? FileManager.default.removeItem(at: tmpURL)
            throw LedgerStoreError.writeFailure("Cannot rename \(tmpPath) → \(path): \(error)")
        }
    }

    private static func ensureDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw LedgerStoreError.writeFailure("Cannot create directory \(path): \(error)")
        }
    }

    static func validateLedger(
        _ ledger: UsageLedger,
        expectedUsername: String,
        expectedDate: String
    ) throws {
        guard ledger.username == expectedUsername else {
            throw LedgerStoreError.validationFailure(
                "Ledger username '\(ledger.username)' does not match '\(expectedUsername)'"
            )
        }
        guard ledger.date == expectedDate else {
            throw LedgerStoreError.validationFailure(
                "Ledger date '\(ledger.date)' does not match '\(expectedDate)'"
            )
        }
        guard ledger.countedSeconds >= 0 else {
            throw LedgerStoreError.validationFailure(
                "counted_seconds is negative: \(ledger.countedSeconds)"
            )
        }
    }
}

// MARK: - Quota math

public enum QuotaMath {
    /// Compute remaining seconds given policy and ledger.
    /// A negative result is clamped to zero.
    public static func remainingSeconds(policy: UserPolicy, ledger: UsageLedger) -> Int {
        max(0, policy.dailyLimitSeconds - ledger.countedSeconds)
    }

    /// Build a DaemonStatus from a policy + ledger + current date string.
    public static func buildStatus(policy: UserPolicy, ledger: UsageLedger, currentDate: String) -> DaemonStatus {
        let remaining = remainingSeconds(policy: policy, ledger: ledger)
        return DaemonStatus(
            username: policy.username,
            enabled: policy.enabled,
            dailyLimitSeconds: policy.dailyLimitSeconds,
            countedSeconds: ledger.countedSeconds,
            remainingSeconds: remaining,
            exhausted: ledger.exhausted,
            currentDate: currentDate,
            gracePeriodSeconds: policy.gracePeriodSeconds,
            enforcementMode: policy.enforcementMode,
            graceStartedAt: ledger.graceStartedAt,
            warningThresholdSeconds: policy.warningThresholdSeconds
        )
    }

    /// Maximum accepted active delta per tick (seconds). Larger values are rejected.
    public static let maxAcceptedDeltaSeconds = 60

    /// Validate an incoming active delta. Returns the clamped value or nil to reject entirely.
    public static func validateDelta(_ delta: Int) -> Int? {
        guard delta >= 0 else { return nil }
        guard delta <= maxAcceptedDeltaSeconds else { return nil }
        return delta
    }
}
