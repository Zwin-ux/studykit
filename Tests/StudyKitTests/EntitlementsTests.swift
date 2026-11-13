import XCTest
@testable import StudyKit

/// Stands in for StoreKit: whatever this app currently owns.
private final class FakeStore: PurchaseSource, @unchecked Sendable {
    private let lock = NSLock()
    private var owned: Set<StudyProduct>
    init(_ owned: Set<StudyProduct> = []) { self.owned = owned }
    func set(_ new: Set<StudyProduct>) { lock.withLock { owned = new } }
    func currentEntitlements() async -> Set<StudyProduct> { lock.withLock { owned } }
}

final class EntitlementsTests: XCTestCase {
    func testBundleUnlocksBothAndSinglesUnlockOne() {
        XCTAssertEqual(StudyAccess(owned: []), StudyAccess(owned: [.removeAds]))
        XCTAssertFalse(StudyAccess(owned: [.removeAds]).book)
        XCTAssertTrue(StudyAccess(owned: [.book]).book)
        XCTAssertFalse(StudyAccess(owned: [.book]).exams)
        XCTAssertTrue(StudyAccess(owned: [.exams]).exams)
        let bundle = StudyAccess(owned: [.bundle])
        XCTAssertTrue(bundle.book && bundle.exams)
    }

    func testProductIDsAreStableAndBelongToOneApp() {
        XCTAssertEqual(StudyProduct.book.rawValue, "com.bonelli.nursebook.fundamentals.full")
        XCTAssertEqual(StudyProduct.exams.rawValue, "com.bonelli.nursebook.entrance.full")
        XCTAssertEqual(StudyProduct.allCases.filter { $0.app == .oneMoreShift }, [.removeAds])
    }

    func testAnAppCanOnlyVouchForItsOwnProducts() {
        let forged = AppOwnership(app: .oneMoreShift, owned: [.book, .bundle, .removeAds])
        XCTAssertEqual(forged.owned, [.removeAds])
        XCTAssertEqual(AppOwnership(app: .nursebook, owned: [.removeAds]).owned, [])
    }

    func testAdsRemovedByOwnPurchaseOrAnyNursebookUnlock() {
        XCTAssertFalse(OwnershipFlags().adsRemoved)
        XCTAssertFalse(OwnershipFlags([AppOwnership(app: .nursebook, owned: [])]).adsRemoved)
        XCTAssertTrue(OwnershipFlags([AppOwnership(app: .oneMoreShift, owned: [.removeAds])]).adsRemoved)
        for product in [StudyProduct.book, .exams, .bundle] {
            XCTAssertTrue(OwnershipFlags([AppOwnership(app: .nursebook, owned: [product])]).adsRemoved, product.rawValue)
        }
    }

    func testNewerRecordWinsSoARefundClearsTheFlag() {
        var flags = OwnershipFlags([AppOwnership(app: .nursebook, owned: [.book], checkedAt: date("2026-11-12T18:00:00Z"))])
        XCTAssertFalse(flags.merge(AppOwnership(app: .nursebook, owned: [], checkedAt: date("2026-11-11T18:00:00Z"))), "older check ignored")
        XCTAssertTrue(flags.adsRemoved)
        XCTAssertTrue(flags.merge(AppOwnership(app: .nursebook, owned: [], checkedAt: date("2026-11-13T18:00:00Z"))))
        XCTAssertFalse(flags.adsRemoved)
    }

    func testNursebookPurchaseRemovesGameAdsOnTheSameDeviceWithoutICloud() async throws {
        let cloud = FakeCloud(); await cloud.setOnline(false)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let book = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: cloud)
        var removed = await game.adsRemoved()
        XCTAssertFalse(removed)

        let store = FakeStore([.exams])
        try await book.refreshOwnership(from: store, now: date("2026-11-12T18:00:00Z"))
        removed = await game.adsRemoved()
        XCTAssertTrue(removed)

        store.set([])  // refund
        try await book.refreshOwnership(from: store, now: date("2026-11-13T18:00:00Z"))
        removed = await game.adsRemoved()
        XCTAssertFalse(removed)
    }

    func testPurchaseAndRefundReachTheOtherDeviceThroughSync() async throws {
        let cloud = FakeCloud()
        let phone = tempDir(), tablet = tempDir()
        defer { try? FileManager.default.removeItem(at: phone); try? FileManager.default.removeItem(at: tablet) }
        let book = try SyncEngine(directory: phone, app: .nursebook, transport: cloud)
        let game = try SyncEngine(directory: tablet, app: .oneMoreShift, transport: cloud)

        let store = FakeStore([.bundle])
        try await book.refreshOwnership(from: store, now: date("2026-11-12T18:00:00Z"))
        await book.sync(); await game.sync()
        var removed = await game.adsRemoved()
        XCTAssertTrue(removed)

        store.set([])
        try await book.refreshOwnership(from: store, now: date("2026-11-13T18:00:00Z"))
        await book.sync(); await game.sync()
        removed = await game.adsRemoved()
        XCTAssertFalse(removed)
        let pending = await book.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testARemoteCopyNeverOverridesWhatThisAppsStoreSays() async throws {
        // Someone edits their own iCloud record to claim a Nursebook unlock with a far-future date.
        let cloud = FakeCloud()
        try await cloud.upload(ownership: AppOwnership(app: .nursebook, owned: [.bundle], checkedAt: date("2099-01-01T00:00:00Z")))
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let book = try SyncEngine(directory: dir, app: .nursebook, transport: cloud)
        let store = FakeStore([])
        try await book.refreshOwnership(from: store, now: date("2026-11-12T18:00:00Z"))
        await book.sync()
        let mine = await book.ownership.records[.nursebook]
        XCTAssertEqual(mine?.owned, [], "Nursebook trusts only its own StoreKit")
        let owned = await store.currentEntitlements()
        XCTAssertFalse(StudyAccess(owned: owned).book)
    }

    func testUnchangedOwnershipIsNotReuploaded() async throws {
        let cloud = FakeCloud()
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let game = try SyncEngine(directory: dir, app: .oneMoreShift, transport: cloud)
        let store = FakeStore([.removeAds])
        try await game.refreshOwnership(from: store, now: date("2026-11-12T18:00:00Z"))
        await game.sync()
        try await game.refreshOwnership(from: store, now: date("2026-11-12T19:00:00Z"))
        let pending = await game.pendingCount
        XCTAssertEqual(pending, 0)
        let remote = await cloud.ownership.records[.oneMoreShift]
        XCTAssertEqual(remote?.checkedAt, date("2026-11-12T18:00:00Z"))
    }

    func testOwnershipFileNamedForAnotherAppIsIgnored() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = OwnershipFiles(directory: dir, app: .oneMoreShift)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The game's file claiming to speak for Nursebook.
        try JSONEncoder().encode(AppOwnership(app: .nursebook, owned: [.book])).write(to: files.url(.oneMoreShift))
        XCTAssertFalse(try files.load().adsRemoved)
    }
}
