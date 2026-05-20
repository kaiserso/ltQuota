import Foundation
import IOKit

/// Measures how long the current session has been idle (no HID input).
/// Uses the IOHIDSystem registry entry — no Accessibility TCC permission required.
public struct IdleMonitor: Sendable {

    /// Returns seconds since the last user input event.
    public static func secondsSinceLastInput() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return 0 }
        defer { IOObjectRelease(service) }

        guard
            let unmanaged = IORegistryEntryCreateCFProperty(
                service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0),
            let nanoseconds = unmanaged.takeRetainedValue() as? NSNumber
        else { return 0 }

        return Double(nanoseconds.uint64Value) / 1_000_000_000.0
    }

    public static func isIdle(threshold: TimeInterval) -> Bool {
        secondsSinceLastInput() >= threshold
    }
}
