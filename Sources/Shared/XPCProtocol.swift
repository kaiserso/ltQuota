import Foundation

// MARK: - XPC service name

public enum XPCServiceName {
    public static let daemon = "com.localtimequota.daemon"
}

// MARK: - XPC Protocol
//
// All methods use Data-encoded JSON payloads rather than ObjC-typed parameters so
// that Codable Swift structs can cross the XPC boundary without mapping to ObjC types.
// Each reply block signature is (Data?, String?) where the String? is an error message.

@objc public protocol LocalTimeQuotaXPC {

    // MARK: Agent / read-only commands

    /// Returns a JSON-encoded DaemonStatus for `username` on the current local date.
    func getStatus(username: String, reply: @escaping (Data?, String?) -> Void)

    /// Accepts a JSON-encoded AddUsageRequest.
    /// Returns a JSON-encoded DaemonStatus after applying the delta.
    func addUsage(requestData: Data, reply: @escaping (Data?, String?) -> Void)

    /// Marks the start of the grace period for `username` / `sessionId`.
    /// Idempotent if grace was already started.
    func beginGrace(username: String, sessionId: String, reply: @escaping (String?) -> Void)

    // MARK: Admin / root-only commands
    // The daemon checks connection.effectiveUserIdentifier == 0 before executing these.

    /// Returns a JSON-encoded UserPolicy for `username`.
    func getPolicy(username: String, reply: @escaping (Data?, String?) -> Void)

    /// Accepts a JSON-encoded UserPolicy and replaces the stored policy.
    func setPolicy(policyData: Data, reply: @escaping (String?) -> Void)

    /// Adds `seconds` to the effective daily allowance for today.
    func grantBonus(username: String, seconds: Int, reply: @escaping (String?) -> Void)

    /// Resets today's counted time and clears the exhausted/grace state.
    func resetToday(username: String, reply: @escaping (String?) -> Void)

    /// Performs immediate enforcement (logout or lock) for `username`.
    /// Callable by the agent (as the child user) or by root.
    func forceEnforce(username: String, reply: @escaping (String?) -> Void)

    /// Returns a JSON-encoded [String] list of managed usernames.
    func listManagedUsers(reply: @escaping (Data?, String?) -> Void)

    /// Returns a JSON-encoded [LedgerEvent] for `username`, newest first, capped at `limit`.
    func getRecentEvents(username: String, limit: Int, reply: @escaping (Data?, String?) -> Void)
}

// MARK: - XPC helper: encode/decode across the boundary

public enum XPCCoder {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
