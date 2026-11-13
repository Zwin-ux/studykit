import XCTest
import CloudKit
@testable import StudyKit
@testable import StudyKitAds

private final class Store: PurchaseSource, @unchecked Sendable {
    private let lock = NSLock()
    private var owned: Set<StudyProduct>
    init(_ owned: Set<StudyProduct> = []) { self.owned = owned }
    func set(_ new: Set<StudyProduct>) { lock.withLock { owned = new } }
    func currentEntitlements() async -> Set<StudyProduct> { lock.withLock { owned } }
}

private actor Ads: RewardedAdProvider {
    func isReady(_ p: AdPlacement) async -> Bool { true }
    func show(_ p: AdPlacement) async -> AdOutcome { .rewarded }
}

private let pst = -8 * 3600
private let t0 = date("2026-11-12T18:00:00Z")
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

/// Both apps as two engines over one fake iCloud (separate local folders), plus the game's ad gate.
private struct Rig {
    let cloud = FakeCloud()
    let bookDir = tempDir(), gameDir = tempDir()
    let book: SyncEngine, game: SyncEngine
    let gate: AdGate
    init() throws {
        book = try SyncEngine(directory: bookDir, app: .nursebook, transport: cloud)
        game = try SyncEngine(directory: gameDir, app: .oneMoreShift, transport: cloud)
        gate = AdGate(directory: gameDir, provider: Ads())
    }
    func cleanup() { try? FileManager.default.removeItem(at: bookDir); try? FileManager.default.removeItem(at: gameDir) }
    /// What the game does at launch: refresh its own purchases, sync, then ask the gate.
    func gameLaunch(_ store: Store, now: Date) async throws -> AdRefusal? {
        try await game.refreshOwnership(from: store, now: now)
        await game.sync(now: now)
        return await gate.refusal(for: .revive, context: AdContext(adsRemoved: await game.adsRemoved()))
    }
}

final class CrossAppIntegrationTests: XCTestCase {
    func testNursebookPurchaseRemovesGameAdsAndRefundRestoresThem() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let bookStore = Store(), gameStore = Store()
        var refusal = try await rig.gameLaunch(gameStore, now: at(0))
        XCTAssertNil(refusal, "free player is offered ads")

        bookStore.set([.book])
        try await rig.book.refreshOwnership(from: bookStore, now: at(1))
        await rig.book.sync(now: at(1))
        refusal = try await rig.gameLaunch(gameStore, now: at(2))
        XCTAssertEqual(refusal, .adsRemoved)

        // Refund: newer record without the product.
        bookStore.set([])
        try await rig.book.refreshOwnership(from: bookStore, now: at(3))
        await rig.book.sync(now: at(3))
        refusal = try await rig.gameLaunch(gameStore, now: at(4))
        XCTAssertNil(refusal, "refund restores ads; stale owned record cannot win")

        // Buy again, then the game relaunches with a stale local copy: newest still wins.
        bookStore.set([.exams])
        try await rig.book.refreshOwnership(from: bookStore, now: at(5))
        await rig.book.sync(now: at(5))
        refusal = try await rig.gameLaunch(gameStore, now: at(6))
        XCTAssertEqual(refusal, .adsRemoved)
    }

    func testRefundStillWinsWhenTheDeviceClockWentBackwards() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let bookStore = Store([.book])
        try await rig.book.refreshOwnership(from: bookStore, now: at(100))
        await rig.book.sync(now: at(100))
        bookStore.set([])
        try await rig.book.refreshOwnership(from: bookStore, now: at(10))  // clock set back
        let own = await rig.book.ownership
        XCTAssertEqual(own.records[.nursebook]?.owned, [])
        await rig.book.sync(now: at(10))
        let refusal = try await rig.gameLaunch(Store(), now: at(11))
        XCTAssertNil(refusal)
    }

    func testBundleAndGameRemoveAdsBothCount() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try await rig.book.refreshOwnership(from: Store([.bundle]), now: at(1))
        await rig.book.sync(now: at(1))
        var refusal = try await rig.gameLaunch(Store(), now: at(2))
        XCTAssertEqual(refusal, .adsRemoved)

        let rig2 = try Rig(); defer { rig2.cleanup() }
        refusal = try await rig2.gameLaunch(Store([.removeAds]), now: at(1))
        XCTAssertEqual(refusal, .adsRemoved)
        // Nursebook sees nothing of it: only adsRemoved crosses, and only toward the game.
        await rig2.book.sync()
        let bookOwn = await rig2.book.ownership
        XCTAssertFalse(bookOwn.records[.nursebook]?.owned.contains(.removeAds) ?? false)
        let access = StudyAccess(owned: bookOwn.records[.nursebook]?.owned ?? [])
        XCTAssertFalse(access.book || access.exams)
    }

    func testOwnershipNeverComesBackFromTheCloudForTheAppsOwnRecord() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        // A forged/stale cloud copy claiming the game owns removeAds, newer than anything local.
        try await rig.cloud.upload(ownership: AppOwnership(app: .oneMoreShift, owned: [.removeAds], checkedAt: at(500)))
        await rig.game.sync(now: at(501))
        let removed = await rig.game.adsRemoved()
        XCTAssertFalse(removed, "game trusts only its own StoreKit for its own record")
    }

    func testOfflineNursebookEventReachesGameExactlyOnce() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        await rig.cloud.setOnline(false)
        let read = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s01", at: at(0), utcOffset: pst)
        try await rig.book.record(read)
        let paused = await rig.book.sync()
        XCTAssertEqual(paused, .paused)
        await rig.cloud.setOnline(true)
        await rig.book.sync(); await rig.game.sync()
        var xp = await rig.game.ledger.xp
        XCTAssertEqual(xp, 5)

        // Duplicate re-upload (second device re-reads the section the same day) and repeat syncs don't double count.
        let dup = StudyEvent.oncePerDay(.sectionRead, app: .nursebook, subject: "ch01-s01", at: at(30), utcOffset: pst)
        try await rig.cloud.upload(events: [read, dup, read])
        await rig.game.sync(); await rig.game.sync(); await rig.book.sync()
        xp = await rig.game.ledger.xp
        XCTAssertEqual(xp, 5)
        let bookXP = await rig.book.ledger.xp
        XCTAssertEqual(bookXP, 5)

        // And the other direction: a shift finished offline in the game.
        await rig.cloud.setOnline(false)
        try await rig.game.record(StudyEvent(kind: .shiftDone, app: .oneMoreShift, at: at(60), utcOffset: pst, xp: 14))
        await rig.game.sync()
        await rig.cloud.setOnline(true)
        await rig.game.sync(); await rig.book.sync()
        let total = await rig.book.ledger.xp
        XCTAssertEqual(total, 19)
    }

    func testProfileSetInGameAppearsInNursebookNewerWins() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let older = Profile(avatar: Avatar(shape: .bun, hair: .silver), updatedAt: at(1))
        let newer = Profile(avatar: Avatar(shape: .ponytail, hair: .black), displayName: "Maya", updatedAt: at(2))
        try await rig.book.setProfile(older)
        try await rig.game.setProfile(newer)
        await rig.book.sync(); await rig.game.sync(); await rig.book.sync()
        let seenInBook = await rig.book.profile, seenInGame = await rig.game.profile
        XCTAssertEqual(seenInBook, newer)
        XCTAssertEqual(seenInGame, newer)
    }

    func testBothEnginesStayUsableWhenCloudFails() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        await rig.cloud.setOnline(false)
        try await rig.book.refreshOwnership(from: Store([.book]), now: at(1))
        try await rig.book.record(StudyEvent(kind: .drillDone, app: .nursebook, at: at(2), utcOffset: pst))
        try await rig.game.record(StudyEvent(kind: .shiftDone, app: .oneMoreShift, at: at(3), utcOffset: pst, xp: 12))
        try await rig.game.setProfile(Profile(avatar: Avatar(), updatedAt: at(4)))
        let s1 = await rig.book.sync(), s2 = await rig.game.sync()
        XCTAssertEqual(s1, .paused); XCTAssertEqual(s2, .paused)
        let bookXP = await rig.book.ledger.xp, gameXP = await rig.game.ledger.xp
        XCTAssertEqual(bookXP, 10); XCTAssertEqual(gameXP, 12)
        let pending = await rig.book.pendingCount
        XCTAssertEqual(pending, 2)
        // Ads decision still works offline (no purchase known on the game side, no crash, ads allowed).
        let refusal = await rig.gate.refusal(for: .revive, context: AdContext(adsRemoved: await rig.game.adsRemoved()))
        XCTAssertNil(refusal)
    }
}

/// Same App Group folder for both apps, no cloud at all.
final class SharedAppGroupIntegrationTests: XCTestCase {
    func testNursebookPurchaseRemovesGameAdsOnSameDeviceWithoutICloud() async throws {
        let cloud = FakeCloud(); await cloud.setOnline(false)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: cloud)   // game already running/launched
        var removed = await game.adsRemoved()
        XCTAssertFalse(removed)
        let book = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        let store = Store([.bundle])
        try await book.refreshOwnership(from: store, now: at(1))
        removed = await game.adsRemoved()
        XCTAssertTrue(removed, "game re-reads the shared file")
        store.set([])
        try await book.refreshOwnership(from: store, now: at(2))
        removed = await game.adsRemoved()
        XCTAssertFalse(removed)
    }

    func testStaleEngineCannotClobberTheOtherAppsNewerProfile() async throws {
        let cloud = FakeCloud(); await cloud.setOnline(false)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: cloud)
        let book = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        try await game.setProfile(Profile(avatar: Avatar(shape: .bun, hair: .silver), updatedAt: at(1)))
        // Game is running with the old profile in memory when Nursebook picks a new one.
        let newer = Profile(avatar: Avatar(shape: .ponytail, hair: .black), displayName: "Maya", updatedAt: at(2))
        try await book.setProfile(newer)
        try await game.record(StudyEvent(kind: .shiftDone, app: .oneMoreShift, at: at(3), utcOffset: pst, xp: 10))
        let onDisk = try ProfileFile(directory: dir).load()
        XCTAssertEqual(onDisk, newer)
        let inGame = await game.profile
        XCTAssertEqual(inGame, newer)
    }

    func testSyncPicksUpTheOtherAppsEventsAfterLaunch() async throws {
        let cloud = FakeCloud(); await cloud.setOnline(false)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: cloud)
        let book = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        try await book.record(StudyEvent(kind: .examDone, app: .nursebook, at: at(1), utcOffset: pst))
        await game.sync()  // paused, but still reads the shared folder
        let xp = await game.ledger.xp
        XCTAssertEqual(xp, 25)
    }

    func testUnsignedFallbackFolderWithNoCloudKeepsWorking() async throws {
        // No App Group container: the app uses its own folder and a transport that always fails.
        struct NoCloud: SyncTransport {
            struct Off: Error {}
            func upload(events: [StudyEvent]) async throws { throw Off() }
            func upload(profile: Profile) async throws { throw Off() }
            func upload(ownership: AppOwnership) async throws { throw Off() }
            func fetch() async throws -> RemoteSnapshot { throw Off() }
        }
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: NoCloud())
        try await game.record(StudyEvent(kind: .shiftDone, app: .oneMoreShift, xp: 9))
        let state = await game.sync()
        XCTAssertEqual(state, .paused)
        let removed = await game.adsRemoved()
        XCTAssertFalse(removed)
        let again = try SyncEngine(directory: dir, app: .oneMoreShift, transport: NoCloud())
        let xp = await again.ledger.xp
        XCTAssertEqual(xp, 9)
    }
}

final class CloudKitRecordParsingTests: XCTestCase {
    func testRefundRecordWithEmptyOwnedListStillParses() {
        let id = CKRecord.ID(recordName: "ownership-nursebook", zoneID: CKRecordZone.ID(zoneName: "Study", ownerName: CKCurrentUserDefaultName))
        let record = CKRecord(recordType: "Ownership", recordID: id)
        record["app"] = "nursebook"
        record["checkedAt"] = at(5)
        // CloudKit returns an empty array field as absent.
        let parsed = CloudKitTransport.ownership(record)
        XCTAssertEqual(parsed, AppOwnership(app: .nursebook, owned: [], checkedAt: at(5)))
    }

    func testProfileRecordFromANewerBuildKeepsItsAvatarSlug() {
        let id = CKRecord.ID(recordName: "profile", zoneID: CKRecordZone.ID(zoneName: "Study", ownerName: CKCurrentUserDefaultName))
        let record = CKRecord(recordType: "Profile", recordID: id)
        record["avatar"] = "v3.straight.tone9.locs.black"
        record["pronouns"] = "she"
        record["updatedAt"] = at(6)
        let parsed = CloudKitTransport.profile(record)
        XCTAssertEqual(parsed?.avatarSlug, "v3.straight.tone9.locs.black")
        XCTAssertEqual(parsed?.pronouns, .she)
        XCTAssertEqual(parsed?.avatar, Avatar())
    }
}
