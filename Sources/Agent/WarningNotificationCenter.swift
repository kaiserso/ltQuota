import Foundation

/// Warning notifier used by the agent.
/// In this launchd binary context (non-app bundle), UserNotifications can throw
/// NSInternalInconsistencyException on newer macOS releases, so we keep this
/// implementation as a safe no-op logger.
@MainActor
final class WarningNotificationCenter {
    static let shared = WarningNotificationCenter()
    private init() {}

    /// Log an early warning event.
    func sendEarlyWarning(remainingSeconds: Int) {
        AgentLogger.log(event: "warning_early", fields: ["remaining_seconds": "\(remainingSeconds)"])
    }

    /// Log a final warning event.
    func sendFinalWarning(remainingSeconds: Int) {
        AgentLogger.log(event: "warning_final", fields: ["remaining_seconds": "\(remainingSeconds)"])
    }

    /// Log immediate action warning event.
    func sendImmediateActionWarning() {
        AgentLogger.log(event: "warning_immediate_action")
    }

    /// No-op in logger-only mode.
    func clearAllNotifications() {
        // Intentionally empty.
    }
}
