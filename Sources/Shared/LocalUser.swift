import Foundation

/// Resolves and validates a local macOS user account by POSIX short name.
public struct LocalUser: Sendable {
    /// The POSIX short username (e.g. "gid", not "Gidda").
    public let shortName: String
    /// The numeric uid.
    public let uid: uid_t
    /// The display (full) name, if available.
    public let fullName: String?

    /// Look up a user by their short name. Returns nil if no such user exists.
    public static func lookup(shortName: String) -> LocalUser? {
        guard let pw = getpwnam(shortName),
              let name = String(validatingUTF8: pw.pointee.pw_name)
        else { return nil }
        let gecos = pw.pointee.pw_gecos.map { String(validatingUTF8: $0) } ?? nil
        return LocalUser(shortName: name, uid: pw.pointee.pw_uid, fullName: gecos)
    }

    /// Look up a user by uid. Returns nil if no such user exists.
    public static func lookup(uid: uid_t) -> LocalUser? {
        guard let pw = getpwuid(uid),
              let name = String(validatingUTF8: pw.pointee.pw_name)
        else { return nil }
        let gecos = pw.pointee.pw_gecos.map { String(validatingUTF8: $0) } ?? nil
        return LocalUser(shortName: name, uid: pw.pointee.pw_uid, fullName: gecos)
    }
}
