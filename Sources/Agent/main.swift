// localtimequota-agent
// Per-user LaunchAgent running in the child's GUI session.
// Tracks active time, reports to daemon, and shows warning UI.
//
// NOTE: We do NOT call NSApplication.shared / app.run() at startup.
// Using NSApplication from a non-app-bundle executable crashes on modern macOS.
// Instead we run the plain RunLoop and initialise AppKit lazily only when UI
// is needed (NSWindow/NSPanel creation implicitly bootstraps the app context).
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
        // Initialise AppKit application context without calling app.run().
        // This allows NSWindow/NSPanel creation to work while keeping RunLoop control.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

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
// Use the plain RunLoop rather than NSApplication.run() to avoid bundle requirements.

RunLoop.main.run()
