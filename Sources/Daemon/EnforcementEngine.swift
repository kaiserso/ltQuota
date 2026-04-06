import Foundation

/// Performs privileged enforcement actions (logout / lock) on a target user's session.
/// All methods must be called from a process running as root.
public struct EnforcementEngine: Sendable {

    /// Look up the UID for a username using the system's user database.
    public static func uid(for username: String) -> uid_t? {
        guard let pw = getpwnam(username) else { return nil }
        return pw.pointee.pw_uid
    }

    /// Log out a user's entire GUI session.
    /// Uses `launchctl bootout gui/<uid>` which terminates the full Aqua session.
    /// Falls back to screen lock if bootout fails.
    @discardableResult
    public static func logout(username: String) -> Bool {
        guard let uid = uid(for: username) else {
            DaemonLogger.log(user: username, event: "enforcement_error",
                             fields: ["reason": "uid_lookup_failed"])
            return false
        }

        DaemonLogger.log(user: username, event: "enforcement_logout_attempt",
                         fields: ["uid": "\(uid)"])

        let result = run("/bin/launchctl", args: ["bootout", "gui/\(uid)"])
        if result {
            DaemonLogger.log(user: username, event: "enforcement_logout_success")
            return true
        }

        // Fallback: lock the screen
        DaemonLogger.log(user: username, event: "enforcement_logout_failed_falling_back_to_lock")
        return lock(username: username, uid: uid)
    }

    /// Lock the screen for a user's session.
    /// Runs CGSession -suspend as the target user via `launchctl asuser`.
    @discardableResult
    public static func lock(username: String) -> Bool {
        guard let uid = uid(for: username) else {
            DaemonLogger.log(user: username, event: "enforcement_error",
                             fields: ["reason": "uid_lookup_failed_for_lock"])
            return false
        }
        return lock(username: username, uid: uid)
    }

    // MARK: - Private

    private static func lock(username: String, uid: uid_t) -> Bool {
        let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        // Run CGSession as the target user via launchctl asuser
        let result = run("/bin/launchctl", args: [
            "asuser", "\(uid)", cgSession, "-suspend"
        ])
        if result {
            DaemonLogger.log(user: username, event: "enforcement_lock_success")
        } else {
            DaemonLogger.log(user: username, event: "enforcement_lock_failed")
        }
        return result
    }

    /// Run a subprocess synchronously. Returns true if exit code is 0.
    @discardableResult
    static func run(_ executable: String, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Suppress subprocess stdout/stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            DaemonLogger.log(event: "subprocess_error",
                             fields: ["executable": executable, "error": error.localizedDescription])
            return false
        }
    }
}
