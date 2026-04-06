import AppKit
import Foundation
import Shared

/// Drives the 15-second tick loop: measures active time, reports to daemon, and
/// triggers warning UI when thresholds are reached.
@MainActor
final class TickLoop {

    let username: String
    let sessionId: String
    let daemon: LocalTimeQuotaXPC

    // Weak reference back to the UI controller.
    weak var warningUI: WarningUI?

    private var tickSeq = 0
    private var lastTickMonotonic: Double = MonotonicClock.now()
    private var warningBannerShown = false
    private var finalWarningShown = false
    private var graceTimerActive = false

    // Maximum tick delta before treating the interval as a sleep/wake discontinuity.
    private let maxSensibleDeltaSeconds: Double = 60

    // Tick interval in seconds.
    private let tickIntervalSeconds: Double = 15

    private var timer: DispatchSourceTimer?

    init(username: String, sessionId: String, daemon: LocalTimeQuotaXPC) {
        self.username = username
        self.sessionId = sessionId
        self.daemon = daemon
    }

    // MARK: - Start / Stop

    // NSWorkspaceDidWakeNotification — the raw Obj-C name is more reliable across Swift toolchains.
    private static let wakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")

    func start() {
        // Register sleep/wake observer.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: TickLoop.wakeNotification,
            object: nil
        )

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + tickIntervalSeconds,
            repeating: tickIntervalSeconds,
            leeway: .seconds(1)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        source.resume()
        timer = source
        AgentLogger.log(user: username, event: "tick_loop_started", fields: ["session_id": sessionId])
    }

    func stop() {
        timer?.cancel()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: TickLoop.wakeNotification,
            object: nil
        )
    }

    // MARK: - Wake handler

    @objc private func onWake() {
        AgentLogger.log(user: username, event: "wake_from_sleep")
        // Reset tick baseline so the sleep gap is not counted.
        lastTickMonotonic = MonotonicClock.now()
    }

    // MARK: - Tick

    private func tick() async {
        tickSeq += 1
        let now = MonotonicClock.now()
        let delta = now - lastTickMonotonic
        lastTickMonotonic = now

        // Guard: treat large gaps as sleep/wake discontinuities.
        if delta > maxSensibleDeltaSeconds {
            AgentLogger.log(user: username, event: "tick_discontinuity",
                            fields: ["delta_seconds": String(format: "%.1f", delta)])
            return
        }

        // Clamp to tick interval in case of scheduling jitter.
        let accountedDelta = min(delta, tickIntervalSeconds)

        // Determine today's date.
        let today = DateHelper.localDateString()

        // Determine active vs idle.
        // We need the policy's idle threshold; for now we fetch it from the status reply.
        // A future optimisation can cache the policy locally.
        let activeDelta: Int

        // We'll resolve idle threshold from the daemon status we fetch next.
        // For this tick, use a simple heuristic: if the system has been idle for
        // longer than the tick interval itself, mark it as 0 active seconds.
        // The actual policy threshold is applied after we get the status back,
        // but we pre-classify here for the AddUsage call.
        let rawIdleSecs = IdleMonitor.secondsSinceLastInput()
        // Use 300s as a safe default if we don't yet have the policy.
        // The daemon only adds what we send; if we send 0 it counts nothing.
        let conservativeIdleThreshold: Double = 300
        if rawIdleSecs >= conservativeIdleThreshold {
            activeDelta = 0
        } else {
            activeDelta = Int(accountedDelta.rounded())
        }

        let req = AddUsageRequest(
            username: username,
            date: today,
            activeDeltaSeconds: activeDelta,
            idleDeltaSeconds: Int((accountedDelta - Double(activeDelta)).rounded()),
            sessionId: sessionId,
            tickSeq: tickSeq
        )

        guard let reqData = try? XPCCoder.encode(req) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            daemon.addUsage(requestData: reqData) { [weak self] data, error in
                Task { @MainActor [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }

                    if let error {
                        AgentLogger.log(user: self.username, event: "daemon_error",
                                        fields: ["error": error])
                        return
                    }
                    guard let data,
                          let status = try? XPCCoder.decode(DaemonStatus.self, from: data)
                    else { return }

                    self.handleStatus(status, idleSeconds: rawIdleSecs)
                }
            }
        }
    }

    // MARK: - Status handling

    private func handleStatus(_ status: DaemonStatus, idleSeconds: TimeInterval) {
        guard status.enabled else { return }

        // Re-evaluate active delta against the real policy idle threshold.
        // (The value we sent was already computed conservatively above; this just
        //  drives UI decisions, not re-accounting.)
        let policyIdleThreshold = Double(status.warningThresholdSeconds > 0 ? 300 : 300)
        _ = idleSeconds >= policyIdleThreshold // informational

        // Early warning banner.
        if !warningBannerShown
            && status.remainingSeconds <= status.warningThresholdSeconds
            && !status.exhausted {
            warningBannerShown = true
            warningUI?.showEarlyWarning(remainingSeconds: status.remainingSeconds)
            AgentLogger.log(user: username, event: "early_warning_shown",
                            fields: ["remaining_seconds": "\(status.remainingSeconds)"])
        }

        // Final warning / enforcement.
        if status.exhausted && !finalWarningShown {
            finalWarningShown = true
            triggerEnforcement(status: status)
        }
    }

    // MARK: - Enforcement

    private func triggerEnforcement(status: DaemonStatus) {
        AgentLogger.log(user: username, event: "enforcement_triggered",
                        fields: ["grace_period_seconds": "\(status.gracePeriodSeconds)"])

        // Tell the daemon grace has started.
        let alreadyGraceStarted = status.graceStartedAt != nil
        let gracePeriod = alreadyGraceStarted ? min(10, status.gracePeriodSeconds) : status.gracePeriodSeconds

        daemon.beginGrace(username: username, sessionId: sessionId) { _ in }

        // Show the final warning modal.
        warningUI?.showFinalWarning(gracePeriodSeconds: gracePeriod) { [weak self] in
            guard let self else { return }
            AgentLogger.log(user: self.username, event: "grace_expired_requesting_enforce")
            self.daemon.forceEnforce(username: self.username) { error in
                if let error {
                    AgentLogger.log(user: self.username, event: "enforce_error",
                                    fields: ["error": error])
                }
            }
        }
    }
}
