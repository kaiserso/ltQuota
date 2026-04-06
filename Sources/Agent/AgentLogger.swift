import Foundation
import Shared

/// Structured logger for the agent process.
/// Writes JSON lines to stdout (captured by launchd → agent.out.log).
public struct AgentLogger: Sendable {

    public static func log(
        user: String? = nil,
        event: String,
        fields: [String: String] = [:]
    ) {
        var obj: [String: String] = [
            "ts": DateHelper.isoNow(),
            "component": "agent",
            "event": event,
        ]
        if let u = user { obj["user"] = u }
        for (k, v) in fields { obj[k] = v }

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
