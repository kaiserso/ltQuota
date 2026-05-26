import Foundation

/// Warning notifier used by the agent.
/// In this launchd binary context (non-app bundle), UserNotifications can throw
/// NSInternalInconsistencyException on newer macOS releases.
/// We use AppleScript notifications via osascript for user-visible warnings.
@MainActor
final class WarningNotificationCenter {
    static let shared = WarningNotificationCenter()
    private init() {}

    /// Show an early warning notification.
    func sendEarlyWarning(remainingSeconds: Int) {
        let minutes = max(1, (remainingSeconds + 59) / 60)
        let title = "Computer Time Limit"
        let body = "\(minutes) minute\(minutes == 1 ? "" : "s") of computer time remaining today."

        showNotification(title: title, body: body, subtitle: "LocalTimeQuota")
        AgentLogger.log(event: "warning_early", fields: ["remaining_seconds": "\(remainingSeconds)"])
    }

    /// Show a final warning notification.
    func sendFinalWarning(remainingSeconds: Int) {
        let minutes = max(1, (remainingSeconds + 59) / 60)
        let title = "Time Almost Up"
        let body = "Your session will end in \(minutes) minute\(minutes == 1 ? "" : "s"). Save your work now."

        showNotification(title: title, body: body, subtitle: "LocalTimeQuota")
        beep(times: 1)
        AgentLogger.log(event: "warning_final", fields: ["remaining_seconds": "\(remainingSeconds)"])
    }

    /// Show immediate action warning notification.
    func sendImmediateActionWarning() {
        showNotification(
            title: "Session Ending",
            body: "Time is up. Your session is being locked now.",
            subtitle: "LocalTimeQuota"
        )
        beep(times: 2)
        AgentLogger.log(event: "warning_immediate_action")
    }

    /// Notifications are transient; nothing to clear for osascript mode.
    func clearAllNotifications() {
        // Intentionally empty.
    }

    // MARK: - Private

    private func showNotification(title: String, body: String, subtitle: String? = nil) {
        var script = "display notification \"\(escapeAppleScript(body))\" with title \"\(escapeAppleScript(title))\""
        if let subtitle, !subtitle.isEmpty {
            script += " subtitle \"\(escapeAppleScript(subtitle))\""
        }
        _ = runAppleScript(script)
    }

    private func beep(times: Int) {
        guard times > 0 else { return }
        let script = "repeat \(times) times\\nbeep\\nend repeat"
        _ = runAppleScript(script)
    }

    @discardableResult
    private func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            AgentLogger.log(event: "warning_notify_error", fields: ["error": error.localizedDescription])
            return false
        }
    }

    private func escapeAppleScript(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
