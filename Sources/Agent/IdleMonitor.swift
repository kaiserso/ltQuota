import Foundation
import CoreGraphics

/// Measures how long the current GUI session has been idle (no HID input).
/// Uses CGEventSource which is available since macOS 10.4.
public struct IdleMonitor: Sendable {

    /// Returns the number of seconds since the last user input event in this session.
    /// Uses CGEventType(rawValue: ~0) which matches any HID event type.
    public static func secondsSinceLastInput() -> TimeInterval {
        // rawValue ~0 (all bits set) queries across all event types.
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~UInt32(0))!
        )
        return idle
    }

    /// Returns true if the session has been idle for at least `threshold` seconds.
    public static func isIdle(threshold: TimeInterval) -> Bool {
        secondsSinceLastInput() >= threshold
    }
}
