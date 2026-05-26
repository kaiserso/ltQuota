// localtimequota-agent
// Per-user LaunchAgent running in the child's GUI session.
// Tracks active time, reports to daemon, and sends notifications.
// TCC-FREE VERSION: Uses UserNotifications instead of AppKit to avoid TCC prompts.
import Foundation
import Shared

// Disable stdout buffering immediately so every print() reaches the log file
// even if launchd kills/restarts the process before the buffer would flush.
setbuf(stdout, nil)

// Debug: write directly to a known path to confirm the binary is actually executing.
// Remove after confirming logging works.
do {
    let debugPath = "/tmp/ltq-agent-alive"
    let msg = "pid=\(ProcessInfo.processInfo.processIdentifier) uid=\(getuid())\n"
    msg.withCString { ptr in
        let fd = open(debugPath, O_WRONLY | O_CREAT | O_APPEND, 0o666)
        if fd >= 0 { _ = write(fd, ptr, strlen(ptr)); close(fd) }
    }
}

// MARK: - Session identity

let username: String = {
    guard let pw = getpwuid(getuid()), let name = String(validatingUTF8: pw.pointee.pw_name), !name.isEmpty else {
        AgentLogger.log(event: "fatal_error", fields: ["reason": "cannot determine username"])
        exit(1)
    }
    return name
}()

let sessionId: String = {
    let prefix = UUID().uuidString.prefix(8).lowercased()
    return "\(prefix)-\(ProcessInfo.processInfo.processIdentifier)"
}()

AgentLogger.log(user: username, event: "agent_start",
                fields: ["session_id": sessionId,
                         "pid": "\(ProcessInfo.processInfo.processIdentifier)"])

// MARK: - XPC connection to daemon

func makeDaemonProxy() -> (NSXPCConnection, LocalTimeQuotaXPC) {
    let conn = NSXPCConnection(machServiceName: XPCServiceName.daemon, options: .privileged)
    conn.remoteObjectInterface = NSXPCInterface(with: LocalTimeQuotaXPC.self)
    conn.invalidationHandler = {
        AgentLogger.log(user: username, event: "daemon_connection_invalidated")
    }
    conn.interruptionHandler = {
        AgentLogger.log(user: username, event: "daemon_connection_interrupted")
    }
    conn.resume()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        AgentLogger.log(user: username, event: "daemon_proxy_error",
                        fields: ["error": error.localizedDescription])
    } as! LocalTimeQuotaXPC
    return (conn, proxy)
}

let (daemonConnection, daemonProxy) = makeDaemonProxy()

// MARK: - Startup orchestration (deferred to after run loop starts)

DispatchQueue.main.async {
    Task { @MainActor in
        // Initialize notification center for warnings (no TCC required).
        _ = WarningNotificationCenter.shared
        
        // Perform initial status check and start tick loop.
        await initialStatusCheck()
    }
}

@MainActor
func initialStatusCheck() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        daemonProxy.getStatus(username: username) { data, error in
            Task { @MainActor in
                defer { cont.resume() }

                if let error {
                    AgentLogger.log(user: username, event: "initial_status_error",
                                    fields: ["error": error])
                    launchTickLoop()
                    return
                }
                guard let data,
                      let status = try? XPCCoder.decode(DaemonStatus.self, from: data)
                else {
                    AgentLogger.log(user: username, event: "initial_status_parse_error")
                    launchTickLoop()
                    return
                }

                AgentLogger.log(user: username, event: "initial_status",
                                fields: [
                                    "enabled": "\(status.enabled)",
                                    "remaining_seconds": "\(status.remainingSeconds)",
                                ])

                // If already exhausted, show final warning immediately.
                if status.exhausted {
                    AgentLogger.log(user: username, event: "initial_exhausted")
                    WarningNotificationCenter.shared.sendFinalWarning(
                        remainingSeconds: max(0, status.gracePeriodSeconds)
                    )
                }

                launchTickLoop()
            }
        }
    }
}

@MainActor
func launchTickLoop() {
    let loop = TickLoop(username: username, sessionId: sessionId, daemon: daemonProxy)
    loop.start()

    AgentLogger.log(user: username, event: "tick_loop_launched")

    // When run loop exits (should not happen unless terminated), clean up notifications.
    DispatchQueue.main.asyncAfter(deadline: .now() + 86400 * 365) {
        WarningNotificationCenter.shared.clearAllNotifications()
    }
}

// Run the main run loop indefinitely.
RunLoop.main.run()
