// localtimequota-daemon
// Privileged root-level LaunchDaemon.
// Manages policy/ledger state and serves XPC clients.
import Foundation
import Shared

setbuf(stdout, nil)

// MARK: - XPC Listener Delegate

final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate {

    // One handler is created per incoming connection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = DaemonXPCHandler()
        handler.connection = connection

        connection.exportedInterface = NSXPCInterface(with: LocalTimeQuotaXPC.self)
        connection.exportedObject = handler

        connection.invalidationHandler = {
            DaemonLogger.log(event: "connection_invalidated")
        }
        connection.resume()
        DaemonLogger.log(event: "connection_accepted",
                         fields: ["caller_uid": "\(connection.effectiveUserIdentifier)"])
        return true
    }
}

// MARK: - Midnight rollover timer

/// Schedules a one-shot timer to fire just after the next local midnight.
/// On each rollover, logs the day boundary event and reschedules itself.
func scheduleMidnightRollover() {
    let secondsUntilMidnight = DateHelper.secondsUntilMidnight()
    // Add a 2-second buffer so wall-clock is solidly past midnight.
    let fireIn = secondsUntilMidnight + 2

    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + fireIn)
    timer.setEventHandler {
        DaemonLogger.log(event: "day_boundary", fields: ["new_date": DateHelper.localDateString()])
        // Reschedule for the next midnight.
        scheduleMidnightRollover()
    }
    timer.resume()
}

// MARK: - Startup

DaemonLogger.log(event: "daemon_start", fields: ["pid": "\(ProcessInfo.processInfo.processIdentifier)"])

// Ensure storage directories exist.
do {
    let fm = FileManager.default
    for dir in [StoragePaths.policies, StoragePaths.usage, StoragePaths.logs, StoragePaths.state] {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    }
} catch {
    DaemonLogger.log(event: "startup_error", fields: ["reason": error.localizedDescription])
    // Non-fatal: directories may already exist.
}

// Schedule midnight day-boundary rollover.
scheduleMidnightRollover()

// Start the XPC listener.
let delegate = DaemonListenerDelegate()
let listener = NSXPCListener(machServiceName: XPCServiceName.daemon)
listener.delegate = delegate
listener.resume()

DaemonLogger.log(event: "daemon_listening", fields: ["service": XPCServiceName.daemon])

// Run the main run loop indefinitely.
RunLoop.main.run()
