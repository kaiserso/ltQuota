import Foundation
import Shared

/// XPC handler implementing the full LocalTimeQuotaXPC protocol.
/// All methods are called on a serial dispatch queue owned by the listener.
/// State is protected by `stateQueue` — a dedicated serial queue.
final class DaemonXPCHandler: NSObject, LocalTimeQuotaXPC {

    // Serial queue that serialises all state mutations.
    private let stateQueue = DispatchQueue(label: "com.localtimequota.daemon.state")

    // The NSXPCConnection currently servicing this handler instance.
    // Set by the listener delegate before handing the handler to NSXPCConnection.
    var connection: NSXPCConnection?

    // MARK: - Auth helpers

    /// Returns true if the caller is root (effectiveUserIdentifier == 0).
    private func callerIsRoot() -> Bool {
        connection?.effectiveUserIdentifier == 0
    }

    /// Returns the effective UID of the caller.
    private func callerUID() -> UInt32 {
        connection?.effectiveUserIdentifier ?? UInt32.max
    }

    // MARK: - GetStatus

    func getStatus(username: String, reply: @escaping (Data?, String?) -> Void) {
        stateQueue.async {
            do {
                let status = try self.buildCurrentStatus(for: username)
                let data = try XPCCoder.encode(status)
                reply(data, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - AddUsage

    func addUsage(requestData: Data, reply: @escaping (Data?, String?) -> Void) {
        stateQueue.async {
            do {
                let req = try XPCCoder.decode(AddUsageRequest.self, from: requestData)

                // Security: caller's uid must match the username being updated
                // (or caller is root, which allows admin tooling to inject ticks in tests).
                if !self.callerIsRoot() {
                    let expectedUID = EnforcementEngine.uid(for: req.username)
                    guard let euid = expectedUID, self.callerUID() == euid else {
                        reply(nil, "Permission denied: uid mismatch")
                        return
                    }
                }

                guard let policy = try LedgerStore.loadPolicy(for: req.username) else {
                    reply(nil, "No policy for user '\(req.username)'")
                    return
                }

                guard policy.enabled else {
                    // Policy disabled — return current status without counting.
                    let status = try self.buildCurrentStatus(for: req.username)
                    let data = try XPCCoder.encode(status)
                    reply(data, nil)
                    return
                }

                let today = DateHelper.localDateString()
                guard req.date == today else {
                    reply(nil, "Date mismatch: request has '\(req.date)', today is '\(today)'")
                    return
                }

                var ledger = try LedgerStore.loadLedger(for: req.username, date: today)
                    ?? UsageLedger(username: req.username, date: today)

                if ledger.exhausted {
                    // Already exhausted — return current status without adding.
                    let status = QuotaMath.buildStatus(policy: policy, ledger: ledger, currentDate: today)
                    let data = try XPCCoder.encode(status)
                    reply(data, nil)
                    return
                }

                // Validate the active delta.
                guard let validDelta = QuotaMath.validateDelta(req.activeDeltaSeconds) else {
                    DaemonLogger.log(user: req.username, event: "delta_rejected",
                                     fields: ["delta": "\(req.activeDeltaSeconds)", "tick_seq": "\(req.tickSeq)"])
                    reply(nil, "Delta \(req.activeDeltaSeconds)s rejected (out of range)")
                    return
                }

                ledger.countedSeconds += validDelta
                ledger.lastUpdateMonotonic = MonotonicClock.now()
                ledger.lastUpdateWallclock = DateHelper.isoNow()
                ledger.lastAgentBootSessionId = req.sessionId

                // Check warning threshold.
                let remaining = QuotaMath.remainingSeconds(policy: policy, ledger: ledger)
                if !ledger.warningIssued && remaining <= policy.warningThresholdSeconds {
                    ledger.warningIssued = true
                    ledger.events.append(LedgerEvent(ts: DateHelper.isoNow(), type: "warning_threshold"))
                    DaemonLogger.log(user: req.username, event: "warning_threshold",
                                     fields: ["remaining_seconds": "\(remaining)"])
                }

                // Check exhaustion.
                if ledger.countedSeconds >= policy.dailyLimitSeconds {
                    ledger.exhausted = true
                    ledger.events.append(LedgerEvent(ts: DateHelper.isoNow(), type: "quota_exhausted"))
                    DaemonLogger.log(user: req.username, event: "quota_exhausted",
                                     fields: ["counted_seconds": "\(ledger.countedSeconds)"])
                }

                // Cap events list at 100 entries.
                if ledger.events.count > 100 {
                    ledger.events = Array(ledger.events.suffix(100))
                }

                try LedgerStore.saveLedger(ledger)

                DaemonLogger.log(user: req.username, event: "usage_update",
                                 fields: [
                                     "counted_seconds": "\(ledger.countedSeconds)",
                                     "remaining_seconds": "\(QuotaMath.remainingSeconds(policy: policy, ledger: ledger))",
                                     "tick_seq": "\(req.tickSeq)"
                                 ])

                let status = QuotaMath.buildStatus(policy: policy, ledger: ledger, currentDate: today)
                let data = try XPCCoder.encode(status)
                reply(data, nil)

            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - BeginGrace

    func beginGrace(username: String, sessionId: String, reply: @escaping (String?) -> Void) {
        stateQueue.async {
            do {
                let today = DateHelper.localDateString()
                var ledger = try LedgerStore.loadLedger(for: username, date: today)
                    ?? UsageLedger(username: username, date: today)

                if ledger.graceStartedAt == nil {
                    ledger.graceStartedAt = DateHelper.isoNow()
                    ledger.events.append(LedgerEvent(ts: DateHelper.isoNow(), type: "grace_started"))
                    try LedgerStore.saveLedger(ledger)
                    DaemonLogger.log(user: username, event: "grace_started")
                }
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - GetPolicy

    func getPolicy(username: String, reply: @escaping (Data?, String?) -> Void) {
        stateQueue.async {
            do {
                guard let policy = try LedgerStore.loadPolicy(for: username) else {
                    reply(nil, "No policy for user '\(username)'")
                    return
                }
                let data = try XPCCoder.encode(policy)
                reply(data, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - SetPolicy (admin only)

    func setPolicy(policyData: Data, reply: @escaping (String?) -> Void) {
        guard callerIsRoot() else {
            reply("Permission denied: admin only")
            return
        }
        stateQueue.async {
            do {
                let policy = try XPCCoder.decode(UserPolicy.self, from: policyData)
                try LedgerStore.savePolicy(policy)
                DaemonLogger.log(user: policy.username, event: "policy_updated",
                                 fields: ["daily_limit_seconds": "\(policy.dailyLimitSeconds)"])
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - GrantBonus (admin only)

    func grantBonus(username: String, seconds: Int, reply: @escaping (String?) -> Void) {
        guard callerIsRoot() else {
            reply("Permission denied: admin only")
            return
        }
        guard seconds > 0 else {
            reply("Bonus seconds must be positive")
            return
        }
        stateQueue.async {
            do {
                let today = DateHelper.localDateString()
                var ledger = try LedgerStore.loadLedger(for: username, date: today)
                    ?? UsageLedger(username: username, date: today)

                // Subtract bonus from counted_seconds (floor at 0).
                ledger.countedSeconds = max(0, ledger.countedSeconds - seconds)
                ledger.exhausted = false
                ledger.graceStartedAt = nil
                ledger.events.append(LedgerEvent(ts: DateHelper.isoNow(), type: "bonus_granted",
                                                  note: "\(seconds)s"))
                try LedgerStore.saveLedger(ledger)

                DaemonLogger.log(user: username, event: "bonus_granted",
                                 fields: ["bonus_seconds": "\(seconds)",
                                          "new_counted_seconds": "\(ledger.countedSeconds)"])
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - ResetToday (admin only)

    func resetToday(username: String, reply: @escaping (String?) -> Void) {
        guard callerIsRoot() else {
            reply("Permission denied: admin only")
            return
        }
        stateQueue.async {
            do {
                let today = DateHelper.localDateString()
                var ledger = UsageLedger(username: username, date: today)
                ledger.events.append(LedgerEvent(ts: DateHelper.isoNow(), type: "day_reset"))
                try LedgerStore.saveLedger(ledger)
                DaemonLogger.log(user: username, event: "day_reset")
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - ForceEnforce

    func forceEnforce(username: String, reply: @escaping (String?) -> Void) {
        // Callable by the child user (their own uid) or by root.
        let uid = EnforcementEngine.uid(for: username)
        let callerIsOwner = uid != nil && callerUID() == uid
        guard callerIsRoot() || callerIsOwner else {
            reply("Permission denied")
            return
        }

        DaemonLogger.log(user: username, event: "force_enforce_requested")

        stateQueue.async {
            // Log the enforcement event.
            let today = DateHelper.localDateString()
            if var ledger = try? LedgerStore.loadLedger(for: username, date: today) {
                ledger.events.append(LedgerEvent(ts: DateHelper.isoNow(), type: "enforcement_triggered"))
                try? LedgerStore.saveLedger(ledger)
            }

            // Perform enforcement off the state queue so we don't block it.
            DispatchQueue.global().async {
                // Small delay so the agent can display the warning before logout.
                Thread.sleep(forTimeInterval: 0.5)
                EnforcementEngine.logout(username: username)
            }
            reply(nil)
        }
    }

    // MARK: - ListManagedUsers (admin only)

    func listManagedUsers(reply: @escaping (Data?, String?) -> Void) {
        guard callerIsRoot() else {
            reply(nil, "Permission denied: admin only")
            return
        }
        stateQueue.async {
            let users = LedgerStore.listManagedUsers()
            do {
                let data = try XPCCoder.encode(users)
                reply(data, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - GetRecentEvents (admin only)

    func getRecentEvents(username: String, limit: Int, reply: @escaping (Data?, String?) -> Void) {
        guard callerIsRoot() else {
            reply(nil, "Permission denied: admin only")
            return
        }
        stateQueue.async {
            do {
                let today = DateHelper.localDateString()
                let ledger = try LedgerStore.loadLedger(for: username, date: today)
                let events = (ledger?.events ?? []).suffix(max(1, limit)).reversed()
                let data = try XPCCoder.encode(Array(events))
                reply(data, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Private helpers

    private func buildCurrentStatus(for username: String) throws -> DaemonStatus {
        guard let policy = try LedgerStore.loadPolicy(for: username) else {
            throw LedgerStoreError.notFound("No policy for '\(username)'")
        }
        let today = DateHelper.localDateString()
        let ledger = (try? LedgerStore.loadLedger(for: username, date: today))
            ?? UsageLedger(username: username, date: today)
        return QuotaMath.buildStatus(policy: policy, ledger: ledger, currentDate: today)
    }
}
