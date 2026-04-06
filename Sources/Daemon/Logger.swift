import Foundation
import Shared

/// Minimal structured logger for the daemon.
/// Writes JSON lines to stdout (captured by launchd → daemon.out.log).
public struct DaemonLogger: Sendable {

    public static func log(
        user: String? = nil,
        event: String,
        fields: [String: String] = [:]
    ) {
        var obj: [String: String] = [
            "ts": DateHelper.isoNow(),
            "component": "daemon",
            "event": event,
        ]
        if let u = user { obj["user"] = u }
        for (k, v) in fields { obj[k] = v }

        // Build a deterministic JSON line (keys sorted).
        let pairs = obj.sorted { $0.key < $1.key }
            .map { "\"\($0.key)\":\"\($0.value.jsonEscaped)\"" }
            .joined(separator: ",")
        print("{\(pairs)}")
    }
}

private extension String {
    var jsonEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
