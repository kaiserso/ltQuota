// localtimequota-agent
// Per-user LaunchAgent running in the child's GUI session.
// Tracks active time, reports to daemon, and shows warning UI.
import AppKit
import Foundation
import Shared

// MARK: - Session identity

let username: String = {
    let name = NSUserName()
    guard !name.isEmpty else {
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

// MARK: - NSApplication setup (no Dock icon, no menu bar)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// MARK: - XPC connection to daemon

func makeDaemonProxy() -> (NSXPCConnection, LocalTimeQuotaXPC) {
    let conn = NSXPCConnection(machServiceName: XPCServiceName.daemon)
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

// MARK: - Main-actor startup orchestration

// Kick off the initial status check on the main actor after the run loop starts.
// We schedule via DispatchQueue.main to avoid Swift 6 top-level actor isolation issues.
DispatchQueue.main.async {
    Task { @MainActor in
        let ui = WarningUI()
        await initialStatusCheck(ui: ui)
    }
}

@MainActor
func initialStatusCheck(ui: WarningUI) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        daemonProxy.getStatus(username: username) { data, error in
            Task { @MainActor in
                defer { cont.resume() }

                if let error {
                    AgentLogger.log(user: username, event: "initial_status_error",
                                    fields: ["error": error])
                    // Start tick loop anyway — daemon may come up shortly.
                    launchTickLoop(ui: ui)
                    return
                }
                guard let data,
                      let status = try? XPCCoder.decode(DaemonStatus.self, from: data)
                else {
                    AgentLogger.log(user: username, event: "initial_status_parse_error")
                    launchTickLoop(ui: ui)
                    return
                }

                AgentLogger.log(user: username, event: "initial_status",
                                fields: [
                                    "counted_seconds": "\(status.countedSeconds)",
                                    "remaining_seconds": "\(status.remainingSeconds)",
                                    "exhausted": "\(status.exhausted)"
                                ])

                if status.exhausted {
                    // Quota already exhausted — show countdown then enforce.
                    let gracePeriod = status.graceStartedAt != nil
                        ? min(10, status.gracePeriodSeconds)
                        : status.gracePeriodSeconds

                    ui.showExhaustedAtLogin(gracePeriodSeconds: gracePeriod) {
                        AgentLogger.log(user: username, event: "exhausted_at_login_enforce")
                        daemonProxy.forceEnforce(username: username) { _ in }
                    }
                } else {
                    launchTickLoop(ui: ui)
                }
            }
        }
    }
}

@MainActor
func launchTickLoop(ui: WarningUI) {
    let loop = TickLoop(username: username, sessionId: sessionId, daemon: daemonProxy)
    loop.warningUI = ui
    loop.start()
    AgentLogger.log(user: username, event: "tick_loop_active")
}

// MARK: - Run loop

app.run()
