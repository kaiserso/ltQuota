import Foundation
import UserNotifications

/// TCC-free warning system using UserNotifications.
/// UNUserNotificationCenter does NOT require any TCC permissions on macOS.
/// This is the safest approach for warning users without triggering TCC prompts.
@MainActor
final class WarningNotificationCenter: NSObject {
    static let shared = WarningNotificationCenter()

    private override init() {
        super.init()
        setupNotifications()
    }

    /// Request notification permission (happens once on first run).
    /// This does NOT trigger TCC — it's a standard notification permission.
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                if granted {
                    // Logger.log(event: "notification_permission_granted")
                } else {
                    // Logger.log(event: "notification_permission_denied")
                }
            }
        }
    }

    /// Send an early warning notification (e.g., "30 minutes remaining").
    func sendEarlyWarning(remainingSeconds: Int) {
        let minutes = max(1, (remainingSeconds + 59) / 60)
        let content = UNMutableNotificationContent()
        content.title = "Computer Time Limit"
        content.body = "\(minutes) minute\(minutes == 1 ? "" : "s") of computer time remaining today."
        content.sound = UNNotificationSound.default

        // Remove any previous early warning
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["ltq_early_warning"]
        )

        let request = UNNotificationRequest(
            identifier: "ltq_early_warning",
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in
            // Notification added (log delivery errors if needed)
        }
    }

    /// Send a final warning notification (e.g., "2 minutes remaining").
    func sendFinalWarning(remainingSeconds: Int) {
        let minutes = max(1, (remainingSeconds + 59) / 60)
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Time Almost Up"
        content.body = "Your session will end in \(minutes) minute\(minutes == 1 ? "" : "s"). Save your work!"
        content.sound = UNNotificationSound.default
        content.badge = NSNumber(value: 1)

        // Remove any previous warnings
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["ltq_final_warning", "ltq_early_warning"]
        )

        let request = UNNotificationRequest(
            identifier: "ltq_final_warning",
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a logout/lock imminent notification.
    func sendImmediateActionWarning() {
        let content = UNMutableNotificationContent()
        content.title = "Session Ending Now"
        content.body = "Your computer session is being locked for rest time."
        content.sound = UNNotificationSound.default
        content.badge = NSNumber(value: 2)

        // Remove all previous warnings
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        let request = UNNotificationRequest(
            identifier: "ltq_immediate_action",
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Clear all pending notifications.
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
