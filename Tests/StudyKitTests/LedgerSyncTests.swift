import XCTest
@testable import StudyKit

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private let pst = -8 * 3600, pdt = -7 * 3600, tokyo = 9 * 3600

/// In-memory iCloud. `online = false` makes every call fail.
private actor FakeCloud: SyncTransport {
    struct Offline: Error {}
    var online = true
    var ledger = Ledger()
    var profile: Profile?
    var uploads = 0
    func setOnline(_ value: Bool) { online = value }
    func upload(events: [StudyEvent]) async throws {
        guard online else { throw Offline() }
        uploads += events.count
        ledger.merge(events)
    }
    func upload(profile new: Profile) async throws {
        guard online else { throw Offline() }
        profile = profile?.merged(with: new) ?? new
    }
    func fetch() async throws -> RemoteSnapshot {
        guard online else { throw Offline() }
        return RemoteSnapshot(events: Array(ledger.events.values), profile: profile)
    }
}

private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

final class LedgerTests: XCTestCase {
    func testSameEventCountsOnce() {
        let event = StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-11-12T18:00:00Z"), utcOffset: pst)
        var ledger = Ledger()
        XCTAssertTrue(ledger.insert(event))
        XCTAssertFalse(ledger.insert(event))
        XCTAssertEqual(ledger.xp, 10)
    }

    func testReadingASectionTwiceInADayIsOneEventOnAnyDevice() {
        let morning = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s01", at: date("2026-11-12T16:00:00Z"), utcOffset: pst)
        let evening = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s01", at: date("2026-11-13T05:00:00Z"), utcOffset: pst)
        let nextDay = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s01", at: date("2026-11-13T16:00:00Z"), utcOffset: pst)
        let other = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s02", at: date("2026-11-12T16:00:00Z"), utcOffset: pst)
        XCTAssertEqual(morning.id, evening.id)
        XCTAssertNotEqual(morning.id, nextDay.id)
        XCTAssertNotEqual(morning.id, other.id)
        XCTAssertEqual(Ledger([morning, evening, nextDay, other]).xp, 15)
    }

    func testMergeConvergesInAnyOrderIncludingConflictingDuplicates() {
        let id = UUID()
        let a = StudyEvent(id: id, kind: .shiftDone, app: .oneMoreShift, at: date("2026-11-12T18:00:00Z"), utcOffset: pst, xp: 30)
        let b = StudyEvent(id: id, kind: .shiftDone, app: .oneMoreShift, at: date("2026-11-12T18:00:00Z"), utcOffset: pst, xp: 12)
        let others = (0..<20).map { StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-11-10T18:00:00Z").addingTimeInterval(Double($0) * 3600), utcOffset: pst) }
        let all = others + [a, b]
        let reference = Ledger(all)
        for _ in 0..<25 { XCTAssertEqual(Ledger(all.shuffled()), reference) }
        XCTAssertEqual(reference.events[id]?.xp, 12)
        var left = Ledger(Array(all.prefix(9))), right = Ledger(Array(all.suffix(15)))
        left.merge(right.events.values); right.merge(left.events.values)
        XCTAssertEqual(left, right)
        XCTAssertEqual(left, reference)
    }

    func testXPIsClampedAndSplitByApp() {
        let ledger = Ledger([
            StudyEvent(kind: .shiftDone, app: .oneMoreShift, xp: 9_999),
            StudyEvent(kind: .shiftDone, app: .oneMoreShift, xp: -5),
            StudyEvent(kind: .examDone, app: .nursebook),
        ])
        XCTAssertEqual(ledger.xp(from: .oneMoreShift), 200)
        XCTAssertEqual(ledger.xp(from: .nursebook), 25)
        XCTAssertEqual(ledger.xp, 225)
    }

    func testStreakCountsLocalDaysAcrossMidnight() {
        // 11:30 pm and 12:30 am Pacific are two days even though both are the same UTC date.
        let ledger = Ledger([
            StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-11-11T07:30:00Z"), utcOffset: pst),
            StudyEvent(kind: .shiftDone, app: .oneMoreShift, at: date("2026-11-11T08:30:00Z"), utcOffset: pst),
        ])
        XCTAssertEqual(ledger.streak(asOf: date("2026-11-11T20:00:00Z"), utcOffset: pst), 2)
        XCTAssertTrue(ledger.studiedToday(asOf: date("2026-11-11T20:00:00Z"), utcOffset: pst))
    }

    func testStreakHoldsUntilADayIsMissedThenResets() {
        let ledger = Ledger((9...11).map { StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-11-\($0 < 10 ? "0" : "")\($0)T20:00:00Z"), utcOffset: pst) })
        XCTAssertEqual(ledger.streak(asOf: date("2026-11-11T22:00:00Z"), utcOffset: pst), 3)
        XCTAssertEqual(ledger.streak(asOf: date("2026-11-12T22:00:00Z"), utcOffset: pst), 3, "yesterday still counts")
        XCTAssertFalse(ledger.studiedToday(asOf: date("2026-11-12T22:00:00Z"), utcOffset: pst))
        XCTAssertEqual(ledger.streak(asOf: date("2026-11-13T22:00:00Z"), utcOffset: pst), 0)
        XCTAssertEqual(Ledger().streak(), 0)
    }

    func testStreakSurvivesTravelAndDaylightSaving() {
        // Los Angeles on the 1st (PDT), clocks change on the 1st, Los Angeles on the 2nd (PST), Tokyo on the 3rd.
        let ledger = Ledger([
            StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-10-31T20:00:00Z"), utcOffset: pdt),
            StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-11-01T20:00:00Z"), utcOffset: pst),
            StudyEvent(kind: .drillDone, app: .nursebook, at: date("2026-11-02T20:00:00Z"), utcOffset: pst),
            StudyEvent(kind: .shiftDone, app: .oneMoreShift, at: date("2026-11-03T03:00:00Z"), utcOffset: tokyo),
        ])
        XCTAssertEqual(ledger.streak(asOf: date("2026-11-03T04:00:00Z"), utcOffset: tokyo), 4)
    }

    func testEachAppWritesItsOwnFileAndReadsBoth() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let book = LedgerFiles(directory: dir, app: .nursebook), game = LedgerFiles(directory: dir, app: .oneMoreShift)
        try book.save(Ledger([StudyEvent(kind: .examDone, app: .nursebook)]))
        try game.save(Ledger([StudyEvent(kind: .shiftDone, app: .oneMoreShift)]))
        XCTAssertEqual(try book.load().xp, 35)
        XCTAssertEqual(try game.load(), try book.load())
        try Data("broken".utf8).write(to: game.url(.oneMoreShift))
        XCTAssertThrowsError(try book.load())
    }
}

final class SyncTests: XCTestCase {
    func testTwoAppsConvergeAndCountEachEventOnce() async throws {
        let cloud = FakeCloud()
        let bookDir = tempDir(), gameDir = tempDir()
        defer { try? FileManager.default.removeItem(at: bookDir); try? FileManager.default.removeItem(at: gameDir) }
        let book = try SyncEngine(directory: bookDir, app: .nursebook, transport: cloud)
        let game = try SyncEngine(directory: gameDir, app: .oneMoreShift, transport: cloud)

        let read = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s01", at: date("2026-11-12T18:00:00Z"), utcOffset: pst)
        try await book.record(read)
        let again = try await book.record(read)
        XCTAssertFalse(again)
        try await game.record(StudyEvent(kind: .shiftDone, app: .oneMoreShift, at: date("2026-11-12T19:00:00Z"), utcOffset: pst, xp: 14))

        await book.sync(); await game.sync(); await book.sync()
        let bookLedger = await book.ledger, gameLedger = await game.ledger
        XCTAssertEqual(bookLedger, gameLedger)
        XCTAssertEqual(bookLedger.xp, 19)
        let uploads = await cloud.uploads
        XCTAssertEqual(uploads, 2, "nothing is re-uploaded once confirmed")
        let pending = await book.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testOfflineWorkQueuesSurvivesRelaunchAndSyncsLater() async throws {
        let cloud = FakeCloud(); await cloud.setOnline(false)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var engine = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        try await engine.record(StudyEvent(kind: .drillDone, app: .nursebook))
        try await engine.record(StudyEvent(kind: .examDone, app: .nursebook))
        let paused = await engine.sync()
        XCTAssertEqual(paused, .paused)
        let xp = await engine.ledger.xp
        XCTAssertEqual(xp, 35, "usable offline")

        engine = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)  // relaunch
        let waiting = await engine.pendingCount
        XCTAssertEqual(waiting, 2)
        await cloud.setOnline(true)
        let now = date("2026-11-12T20:00:00Z")
        let state = await engine.sync(now: now)
        XCTAssertEqual(state, .synced(now))
        let remoteXP = await cloud.ledger.xp
        XCTAssertEqual(remoteXP, 35)
        let left = await engine.pendingCount
        XCTAssertEqual(left, 0)
    }

    func testAvatarPickedInOneAppReachesTheOtherAndNewerWins() async throws {
        let cloud = FakeCloud()
        let bookDir = tempDir(), gameDir = tempDir()
        defer { try? FileManager.default.removeItem(at: bookDir); try? FileManager.default.removeItem(at: gameDir) }
        let book = try SyncEngine(directory: bookDir, app: .nursebook, transport: cloud)
        let game = try SyncEngine(directory: gameDir, app: .oneMoreShift, transport: cloud)

        let first = Profile(avatar: Avatar(shape: .bun, hair: .silver), updatedAt: date("2026-11-12T18:00:00Z"))
        try await book.setProfile(first)
        await book.sync(); await game.sync()
        var seen = await game.profile
        XCTAssertEqual(seen, first)

        // The game changes it later while Nursebook still holds the old one.
        let second = Profile(avatar: Avatar(shape: .ponytail, hair: .black), displayName: "Maya", updatedAt: date("2026-11-12T19:00:00Z"))
        try await game.setProfile(second)
        await game.sync(); await book.sync()
        seen = await book.profile
        XCTAssertEqual(seen, second)

        // A stale device comes back with an older profile: the server copy survives.
        let staleDir = tempDir(); defer { try? FileManager.default.removeItem(at: staleDir) }
        let stale = try SyncEngine(directory: staleDir, app: .nursebook, transport: cloud)
        try await stale.setProfile(Profile(avatar: Avatar(), updatedAt: date("2026-11-01T00:00:00Z")))
        await stale.sync()
        seen = await stale.profile
        XCTAssertEqual(seen, second)
        let remote = await cloud.profile
        XCTAssertEqual(remote, second)
    }

    func testSharedAppGroupFolderShowsTheOtherAppsEventsWithoutICloud() async throws {
        let cloud = FakeCloud(); await cloud.setOnline(false)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: cloud)
        try await game.record(StudyEvent(kind: .shiftDone, app: .oneMoreShift, xp: 20))
        let book = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        let xp = await book.ledger.xp
        XCTAssertEqual(xp, 20)
    }
}
