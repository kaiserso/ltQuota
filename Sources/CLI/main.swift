// quotactl — LocalTimeQuota parent control CLI
// Run as `sudo quotactl <command> [args]` for admin commands.
// Run as `quotactl status <user>` or `quotactl list` without sudo.
import Foundation
import Shared

// MARK: - Exit codes

enum ExitCode: Int32 {
    case success            = 0
    case invalidArgs        = 1
    case permissionDenied   = 2
    case daemonUnavailable  = 3
    case userNotFound       = 4
    case storageError       = 5
}

func exit(_ code: ExitCode) -> Never {
    Foundation.exit(code.rawValue)
}

// MARK: - Duration parser

/// Parses duration strings like "2h", "90m", "5400s" into seconds.
func parseDuration(_ s: String) -> Int? {
    if let val = Int(s) { return val }
    if s.hasSuffix("h"), let h = Int(s.dropLast()) { return h * 3600 }
    if s.hasSuffix("m"), let m = Int(s.dropLast()) { return m * 60 }
    if s.hasSuffix("s"), let sec = Int(s.dropLast()) { return sec }
    return nil
}

func formatDuration(_ seconds: Int) -> String {
    if seconds == 0 { return "0s" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    var parts: [String] = []
    if h > 0 { parts.append("\(h)h") }
    if m > 0 { parts.append("\(m)m") }
    if s > 0 { parts.append("\(s)s") }
    return parts.joined(separator: " ")
}

// MARK: - XPC connection

func makeDaemonProxy(timeout: TimeInterval = 5) -> LocalTimeQuotaXPC? {
    let conn = NSXPCConnection(machServiceName: XPCServiceName.daemon)
    conn.remoteObjectInterface = NSXPCInterface(with: LocalTimeQuotaXPC.self)
    conn.resume()

    let proxy = conn.synchronousRemoteObjectProxyWithErrorHandler { error in
        fputs("quotactl: daemon unavailable: \(error.localizedDescription)\n", stderr)
    } as? LocalTimeQuotaXPC

    if proxy == nil {
        fputs("quotactl: cannot connect to daemon\n", stderr)
    }
    return proxy
}

// MARK: - Command dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("""
    quotactl — LocalTimeQuota parent control tool
    Usage:
      quotactl status <user>
      quotactl list
      quotactl events <user>
      sudo quotactl set <user> <2h|90m|5400s>
      sudo quotactl bonus <user> <15m>
      sudo quotactl reset <user>
      sudo quotactl enable <user>
      sudo quotactl disable <user>
      sudo quotactl set-idle <user> off
      sudo quotactl set-idle <user> on <threshold-seconds>
    """, stderr)
    exit(.invalidArgs)
}

let command = args[1]

switch command {

// MARK: status
case "status":
    guard args.count == 3 else {
        fputs("Usage: quotactl status <user>\n", stderr); exit(.invalidArgs)
    }
    let user = args[2]
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.getStatus(username: user) { data, error in
        defer { sema.signal() }
        if let error {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(ExitCode.userNotFound.rawValue)
        }
        guard let data, let status = try? XPCCoder.decode(DaemonStatus.self, from: data) else {
            fputs("Error: could not parse daemon response\n", stderr)
            Foundation.exit(ExitCode.storageError.rawValue)
        }
        let enabledStr = status.enabled ? "enabled" : "disabled"
        let exhaustedStr = status.exhausted ? " (EXHAUSTED)" : ""
        print("""
        User:          \(status.username)
        Date:          \(status.currentDate)
        Status:        \(enabledStr)\(exhaustedStr)
        Daily limit:   \(formatDuration(status.dailyLimitSeconds))
        Used today:    \(formatDuration(status.countedSeconds))
        Remaining:     \(formatDuration(status.remainingSeconds))
        Enforcement:   \(status.enforcementMode.rawValue)
        Grace period:  \(formatDuration(status.gracePeriodSeconds))
        """)
    }
    sema.wait()

// MARK: list
case "list":
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.listManagedUsers { data, error in
        defer { sema.signal() }
        if let error {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(ExitCode.permissionDenied.rawValue)
        }
        guard let data, let users = try? XPCCoder.decode([String].self, from: data) else {
            fputs("Error: could not parse response\n", stderr)
            Foundation.exit(ExitCode.storageError.rawValue)
        }
        if users.isEmpty {
            print("No managed users.")
        } else {
            users.forEach { print($0) }
        }
    }
    sema.wait()

// MARK: events
case "events":
    guard args.count == 3 else {
        fputs("Usage: quotactl events <user>\n", stderr); exit(.invalidArgs)
    }
    let user = args[2]
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.getRecentEvents(username: user, limit: 20) { data, error in
        defer { sema.signal() }
        if let error {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(ExitCode.permissionDenied.rawValue)
        }
        guard let data, let events = try? XPCCoder.decode([LedgerEvent].self, from: data) else {
            fputs("Error: could not parse response\n", stderr)
            Foundation.exit(ExitCode.storageError.rawValue)
        }
        if events.isEmpty {
            print("No events for today.")
        } else {
            for e in events {
                let note = e.note.map { " — \($0)" } ?? ""
                print("\(e.ts)  \(e.type)\(note)")
            }
        }
    }
    sema.wait()

// MARK: set
case "set":
    guard args.count == 4, let seconds = parseDuration(args[3]) else {
        fputs("Usage: sudo quotactl set <user> <2h|90m|5400s>\n", stderr); exit(.invalidArgs)
    }
    let user = args[2]
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    // Fetch existing policy if present; create a default if none exists yet.
    daemon.getPolicy(username: user) { data, error in
        var policy: UserPolicy
        if let data, let p = try? XPCCoder.decode(UserPolicy.self, from: data) {
            policy = p
        } else {
            // No policy on file yet — create default for this user.
            policy = UserPolicy(username: user)
        }
        policy.dailyLimitSeconds = seconds

        guard let policyData = try? XPCCoder.encode(policy) else {
            sema.signal()
            Foundation.exit(ExitCode.storageError.rawValue)
        }
        daemon.setPolicy(policyData: policyData) { error in
            defer { sema.signal() }
            if let error {
                fputs("Error: \(error)\n", stderr)
                Foundation.exit(ExitCode.permissionDenied.rawValue)
            }
            print("Daily limit for \(user) set to \(formatDuration(seconds)).")
        }
    }
    sema.wait()

// MARK: bonus
case "bonus":
    guard args.count == 4, let seconds = parseDuration(args[3]) else {
        fputs("Usage: sudo quotactl bonus <user> <15m>\n", stderr); exit(.invalidArgs)
    }
    let user = args[2]
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.grantBonus(username: user, seconds: seconds) { error in
        defer { sema.signal() }
        if let error {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(ExitCode.permissionDenied.rawValue)
        }
        print("Granted \(formatDuration(seconds)) bonus time to \(user).")
    }
    sema.wait()

// MARK: reset
case "reset":
    guard args.count == 3 else {
        fputs("Usage: sudo quotactl reset <user>\n", stderr); exit(.invalidArgs)
    }
    let user = args[2]
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.resetToday(username: user) { error in
        defer { sema.signal() }
        if let error {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(ExitCode.permissionDenied.rawValue)
        }
        print("Today's usage reset for \(user).")
    }
    sema.wait()

// MARK: enable / disable
case "enable", "disable":
    guard args.count == 3 else {
        fputs("Usage: sudo quotactl enable|disable <user>\n", stderr); exit(.invalidArgs)
    }
    let user = args[2]
    let enabling = command == "enable"
    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.getPolicy(username: user) { data, error in
        var policy: UserPolicy
        if let data, let p = try? XPCCoder.decode(UserPolicy.self, from: data) {
            policy = p
        } else {
            policy = UserPolicy(username: user)
        }
        policy.enabled = enabling

        guard let policyData = try? XPCCoder.encode(policy) else {
            sema.signal()
            Foundation.exit(ExitCode.storageError.rawValue)
        }
        daemon.setPolicy(policyData: policyData) { error in
            defer { sema.signal() }
            if let error {
                fputs("Error: \(error)\n", stderr)
                Foundation.exit(ExitCode.permissionDenied.rawValue)
            }
            print("Enforcement for \(user) \(enabling ? "enabled" : "disabled").")
        }
    }
    sema.wait()

// MARK: set-idle
case "set-idle":
    // sudo quotactl set-idle alice off
    // sudo quotactl set-idle alice on 300
    guard args.count >= 4 else {
        fputs("Usage: sudo quotactl set-idle <user> off|on [threshold-seconds]\n", stderr)
        exit(.invalidArgs)
    }
    let user = args[2]
    let mode = args[3]
    guard mode == "off" || mode == "on" else {
        fputs("set-idle mode must be 'on' or 'off'\n", stderr); exit(.invalidArgs)
    }
    let threshold: Int?
    if mode == "on" {
        guard args.count == 5, let t = Int(args[4]) else {
            fputs("Usage: sudo quotactl set-idle <user> on <seconds>\n", stderr); exit(.invalidArgs)
        }
        threshold = t
    } else {
        threshold = nil
    }

    guard let daemon = makeDaemonProxy() else { exit(.daemonUnavailable) }

    let sema = DispatchSemaphore(value: 0)
    daemon.getPolicy(username: user) { data, error in
        var policy: UserPolicy
        if let data, let p = try? XPCCoder.decode(UserPolicy.self, from: data) {
            policy = p
        } else {
            policy = UserPolicy(username: user)
        }
        policy.countIdleTime = (mode == "on")
        if let t = threshold { policy.idleThresholdSeconds = t }

        guard let policyData = try? XPCCoder.encode(policy) else {
            sema.signal()
            Foundation.exit(ExitCode.storageError.rawValue)
        }
        daemon.setPolicy(policyData: policyData) { error in
            defer { sema.signal() }
            if let error {
                fputs("Error: \(error)\n", stderr)
                Foundation.exit(ExitCode.permissionDenied.rawValue)
            }
            if mode == "on" {
                print("Idle time now counts for \(user) (threshold: \(threshold!)s).")
            } else {
                print("Idle time now excluded for \(user).")
            }
        }
    }
    sema.wait()

default:
    fputs("quotactl: unknown command '\(command)'\n", stderr)
    exit(.invalidArgs)
}
