import XCTest
import StudyKit
@testable import StudyKitAds

private actor FakeAds: RewardedAdProvider {
    var ready = true
    var outcome = AdOutcome.rewarded
    var requests = 0
    func set(ready: Bool? = nil, outcome: AdOutcome? = nil) {
        if let ready { self.ready = ready }
        if let outcome { self.outcome = outcome }
    }
    func isReady(_ placement: AdPlacement) async -> Bool { ready }
    func show(_ placement: AdPlacement) async -> AdOutcome { requests += 1; return outcome }
}

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private let pst = -8 * 3600
private let free = AdContext(adsRemoved: false)

final class AdGateTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testNoRequestIsMadeWhenAdsAreRemoved() async {
        let ads = FakeAds()
        let gate = AdGate(directory: dir, provider: ads)
        let removed = AdContext(adsRemoved: true)
        let refusal = await gate.refusal(for: .revive, context: removed)
        XCTAssertEqual(refusal, .adsRemoved)
        let granted = await gate.show(.revive, context: removed)
        XCTAssertFalse(granted)
        let requests = await ads.requests
        XCTAssertEqual(requests, 0)
    }

    func testSixthAdInADayIsRefusedLocallyAndTheCapResetsNextDay() async {
        let ads = FakeAds()
        let gate = AdGate(directory: dir, provider: ads)
        let noon = date("2026-11-12T20:00:00Z")
        for _ in 0..<5 {
            let granted = await gate.show(.bonusXP, context: free, now: noon, utcOffset: pst)
            XCTAssertTrue(granted)
        }
        let sixth = await gate.show(.bonusXP, context: free, now: noon, utcOffset: pst)
        XCTAssertFalse(sixth)
        let refusal = await gate.refusal(for: .bonusXP, context: free, now: noon, utcOffset: pst)
        XCTAssertEqual(refusal, .dailyCapReached)
        var requests = await ads.requests
        XCTAssertEqual(requests, 5)

        // 11:59 pm the same local day is still capped; just after local midnight is a new day.
        let late = await gate.refusal(for: .bonusXP, context: free, now: date("2026-11-13T07:59:00Z"), utcOffset: pst)
        XCTAssertEqual(late, .dailyCapReached)
        let next = await gate.show(.bonusXP, context: free, now: date("2026-11-13T08:01:00Z"), utcOffset: pst)
        XCTAssertTrue(next)
        requests = await ads.requests
        XCTAssertEqual(requests, 6)
    }

    func testTheCapSurvivesARelaunch() async {
        let noon = date("2026-11-12T20:00:00Z")
        var gate = AdGate(directory: dir, provider: FakeAds())
        for _ in 0..<5 { _ = await gate.show(.revive, context: free, now: noon, utcOffset: pst) }
        gate = AdGate(directory: dir, provider: FakeAds())
        let shown = await gate.shownToday(now: noon, utcOffset: pst)
        XCTAssertEqual(shown, 5)
        let granted = await gate.show(.revive, context: free, now: noon, utcOffset: pst)
        XCTAssertFalse(granted)
    }

    func testSkippedAdGrantsNothingButUsesASlot() async {
        let ads = FakeAds(); await ads.set(outcome: .skipped)
        let gate = AdGate(directory: dir, provider: ads)
        let noon = date("2026-11-12T20:00:00Z")
        let granted = await gate.show(.cosmeticRoll, context: free, now: noon, utcOffset: pst)
        XCTAssertFalse(granted)
        let shown = await gate.shownToday(now: noon, utcOffset: pst)
        XCTAssertEqual(shown, 1)
    }

    func testFailedAdGrantsNothingKeepsTheSlotAndPausesOffers() async {
        let ads = FakeAds(); await ads.set(outcome: .failed)
        let gate = AdGate(directory: dir, provider: ads)
        let noon = date("2026-11-12T20:00:00Z")
        let granted = await gate.show(.revive, context: free, now: noon, utcOffset: pst)
        XCTAssertFalse(granted)
        let shown = await gate.shownToday(now: noon, utcOffset: pst)
        XCTAssertEqual(shown, 0)

        await ads.set(outcome: .rewarded)
        let soon = await gate.refusal(for: .revive, context: free, now: noon.addingTimeInterval(30), utcOffset: pst)
        XCTAssertEqual(soon, .coolingDown)
        let retry = await gate.show(.revive, context: free, now: noon.addingTimeInterval(30), utcOffset: pst)
        XCTAssertFalse(retry)
        let requests = await ads.requests
        XCTAssertEqual(requests, 1, "no error loop")
        let later = await gate.show(.revive, context: free, now: noon.addingTimeInterval(61), utcOffset: pst)
        XCTAssertTrue(later)
    }

    func testNoAdDuringAPatientQuestionOrWhileTheClockIsPaused() async {
        let ads = FakeAds()
        let gate = AdGate(directory: dir, provider: ads)
        for context in [AdContext(adsRemoved: false, questionPending: true), AdContext(adsRemoved: false, clockPaused: true)] {
            let refusal = await gate.refusal(for: .bonusXP, context: context)
            XCTAssertEqual(refusal, .busy)
            let granted = await gate.show(.bonusXP, context: context)
            XCTAssertFalse(granted)
        }
        let requests = await ads.requests
        XCTAssertEqual(requests, 0)
    }

    func testNotReadyHidesTheOffer() async {
        let ads = FakeAds(); await ads.set(ready: false)
        let gate = AdGate(directory: dir, provider: ads)
        let refusal = await gate.refusal(for: .revive, context: free)
        XCTAssertEqual(refusal, .notReady)
    }

    func testUnreadableTallyRefusesInsteadOfResettingTheCap() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: dir.appendingPathComponent("ad-tally.json"))
        let ads = FakeAds()
        let gate = AdGate(directory: dir, provider: ads)
        let refusal = await gate.refusal(for: .revive, context: free)
        XCTAssertEqual(refusal, .dailyCapReached)
        let granted = await gate.show(.revive, context: free)
        XCTAssertFalse(granted)
        let requests = await ads.requests
        XCTAssertEqual(requests, 0)
    }
}
