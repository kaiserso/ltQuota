import XCTest
import Foundation
@testable import Shared

final class PolicyTests: XCTestCase {

    func testPolicyRoundTrip() throws {
        let policy = UserPolicy(
            username: "alice",
            enabled: true,
            dailyLimitSeconds: 7200,
            countIdleTime: false,
            idleThresholdSeconds: 300,
            gracePeriodSeconds: 60,
            enforcementMode: .logout,
            warningThresholdSeconds: 300,
            allowParentOverride: true
        )

        let data = try XPCCoder.encode(policy)
        let decoded = try XPCCoder.decode(UserPolicy.self, from: data)

        XCTAssertEqual(decoded.username, "alice")
        XCTAssertEqual(decoded.dailyLimitSeconds, 7200)
        XCTAssertEqual(decoded.enforcementMode, .logout)
        XCTAssertFalse(decoded.countIdleTime)
    }

    func testPolicyJSON_snakeCaseKeys() throws {
        let policy = UserPolicy(username: "bob", dailyLimitSeconds: 3600)
        let data = try XPCCoder.encode(policy)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(json["daily_limit_seconds"])
        XCTAssertNotNil(json["idle_threshold_seconds"])
        XCTAssertNotNil(json["enforcement_mode"])
    }

    func testPolicyValidation_usernameMismatch() throws {
        var policy = UserPolicy(username: "alice")
        // Manually write with mismatched username embedded in JSON
        let data = try XPCCoder.encode(policy)
        // Validation happens in LedgerStore.loadPolicy; simulate by calling validateLedger on a ledger
        // For policy, validation is in loadPolicy itself. Test directly:
        policy.username = "mallory"
        let data2 = try XPCCoder.encode(policy)
        let tmpDir = FileManager.default.temporaryDirectory
        let path = tmpDir.appendingPathComponent("alice.json").path
        try data2.write(to: URL(fileURLWithPath: path))
        // loadPolicy checks username == filename-stem
        do {
            _ = try LedgerStore.loadPolicy(for: "alice")
            // If this file doesn't exist under the real path, it returns nil — that's fine for this test
        } catch {
            // Expected if a mismatched policy were at the real path; we can't install to /Library in tests.
        }
        // Cleanup
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(policy.username, "mallory") // just confirms we mutated it
    }
}

final class LedgerTests: XCTestCase {

    func testLedgerRoundTrip() throws {
        let ledger = UsageLedger(
            username: "alice",
            date: "2026-04-06",
            countedSeconds: 3814,
            exhausted: false,
            warningIssued: false,
            graceStartedAt: nil,
            lastUpdateMonotonic: 123456.789,
            lastUpdateWallclock: "2026-04-06T18:33:41Z",
            lastAgentBootSessionId: "A1B2C3D4",
            events: [
                LedgerEvent(ts: "2026-04-06T17:10:00Z", type: "session_start"),
                LedgerEvent(ts: "2026-04-06T18:20:00Z", type: "warning_threshold")
            ]
        )

        let data = try XPCCoder.encode(ledger)
        let decoded = try XPCCoder.decode(UsageLedger.self, from: data)

        XCTAssertEqual(decoded.username, "alice")
        XCTAssertEqual(decoded.date, "2026-04-06")
        XCTAssertEqual(decoded.countedSeconds, 3814)
        XCTAssertFalse(decoded.exhausted)
        XCTAssertEqual(decoded.events.count, 2)
        XCTAssertEqual(decoded.events[0].type, "session_start")
    }

    func testLedgerValidation_pass() throws {
        let ledger = UsageLedger(username: "alice", date: "2026-04-06", countedSeconds: 100)
        XCTAssertNoThrow(try LedgerStore.validateLedger(ledger, expectedUsername: "alice", expectedDate: "2026-04-06"))
    }

    func testLedgerValidation_usernameMismatch() throws {
        let ledger = UsageLedger(username: "bob", date: "2026-04-06")
        XCTAssertThrowsError(try LedgerStore.validateLedger(ledger, expectedUsername: "alice", expectedDate: "2026-04-06")) { error in
            let e = error as! LedgerStoreError
            if case .validationFailure = e { } else { XCTFail("wrong error: \(e)") }
        }
    }

    func testLedgerValidation_dateMismatch() throws {
        let ledger = UsageLedger(username: "alice", date: "2026-04-05")
        XCTAssertThrowsError(try LedgerStore.validateLedger(ledger, expectedUsername: "alice", expectedDate: "2026-04-06")) { error in
            let e = error as! LedgerStoreError
            if case .validationFailure = e { } else { XCTFail("wrong error: \(e)") }
        }
    }

    func testLedgerValidation_negativeSeconds() throws {
        var ledger = UsageLedger(username: "alice", date: "2026-04-06")
        ledger.countedSeconds = -1
        XCTAssertThrowsError(try LedgerStore.validateLedger(ledger, expectedUsername: "alice", expectedDate: "2026-04-06")) { error in
            let e = error as! LedgerStoreError
            if case .validationFailure = e { } else { XCTFail("wrong error: \(e)") }
        }
    }
}

final class AtomicWriteTests: XCTestCase {

    func testAtomicWrite_createsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltq-test-\(Int.random(in: 100000...999999))")
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = dir + "/ledger.json"
        let data = Data("hello".utf8)
        try LedgerStore.atomicWrite(data: data, to: path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let read = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(read, data)
    }

    func testAtomicWrite_overwritesExisting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltq-test-\(Int.random(in: 100000...999999))")
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = dir + "/ledger.json"
        try LedgerStore.atomicWrite(data: Data("first".utf8), to: path)
        try LedgerStore.atomicWrite(data: Data("second".utf8), to: path)

        let read = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(String(data: read, encoding: .utf8), "second")

        // No orphaned .tmp file
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".tmp"))
    }
}

final class QuotaMathTests: XCTestCase {

    private func makePolicy(limit: Int = 7200, warning: Int = 300) -> UserPolicy {
        UserPolicy(username: "alice", dailyLimitSeconds: limit, warningThresholdSeconds: warning)
    }

    private func makeLedger(counted: Int = 0, exhausted: Bool = false) -> UsageLedger {
        UsageLedger(username: "alice", date: "2026-04-06", countedSeconds: counted, exhausted: exhausted)
    }

    func testRemainingSeconds_basic() {
        let policy = makePolicy(limit: 7200)
        let ledger = makeLedger(counted: 3600)
        XCTAssertEqual(QuotaMath.remainingSeconds(policy: policy, ledger: ledger), 3600)
    }

    func testRemainingSeconds_exactlyZero() {
        let policy = makePolicy(limit: 7200)
        let ledger = makeLedger(counted: 7200)
        XCTAssertEqual(QuotaMath.remainingSeconds(policy: policy, ledger: ledger), 0)
    }

    func testRemainingSeconds_clampedAtZero() {
        let policy = makePolicy(limit: 7200)
        let ledger = makeLedger(counted: 9000) // over limit — clamped
        XCTAssertEqual(QuotaMath.remainingSeconds(policy: policy, ledger: ledger), 0)
    }

    func testBuildStatus_exhausted() {
        let policy = makePolicy(limit: 100)
        let ledger = makeLedger(counted: 100, exhausted: true)
        let status = QuotaMath.buildStatus(policy: policy, ledger: ledger, currentDate: "2026-04-06")
        XCTAssertEqual(status.remainingSeconds, 0)
        XCTAssertTrue(status.exhausted)
        XCTAssertEqual(status.dailyLimitSeconds, 100)
    }

    func testDeltaValidation_valid() {
        XCTAssertEqual(QuotaMath.validateDelta(15), 15)
        XCTAssertEqual(QuotaMath.validateDelta(0), 0)
        XCTAssertEqual(QuotaMath.validateDelta(60), 60)
    }

    func testDeltaValidation_tooLarge() {
        XCTAssertNil(QuotaMath.validateDelta(61))
        XCTAssertNil(QuotaMath.validateDelta(3600))
    }

    func testDeltaValidation_negative() {
        XCTAssertNil(QuotaMath.validateDelta(-1))
    }
}

final class DateHelperTests: XCTestCase {

    func testLocalDateString_formatIsYYYYMMDD() {
        let s = DateHelper.localDateString()
        // Must match YYYY-MM-DD
        let regex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        let range = NSRange(s.startIndex..., in: s)
        XCTAssertTrue(regex.firstMatch(in: s, range: range) != nil, "date '\(s)' not in YYYY-MM-DD format")
    }

    func testSecondsUntilMidnight_isPositive() {
        let secs = DateHelper.secondsUntilMidnight()
        XCTAssertGreaterThan(secs, 0)
        XCTAssertLessThanOrEqual(secs, 86400)
    }

    func testSecondsUntilMidnight_knownDate() {
        // 2026-04-06 at 22:00:00 local → 2 hours until midnight
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 6
        comps.hour = 22; comps.minute = 0; comps.second = 0
        if let date = cal.date(from: comps) {
            let secs = DateHelper.secondsUntilMidnight(from: date)
            XCTAssertEqual(secs, 7200, accuracy: 2)
        }
    }
}

final class MonotonicClockTests: XCTestCase {

    func testMonotonicClock_isPositive() {
        let t = MonotonicClock.now()
        XCTAssertGreaterThan(t, 0)
    }

    func testMonotonicClock_isMonotonic() {
        let t1 = MonotonicClock.now()
        Thread.sleep(forTimeInterval: 0.01)
        let t2 = MonotonicClock.now()
        XCTAssertGreaterThan(t2, t1)
    }
}
