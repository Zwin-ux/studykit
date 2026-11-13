import Foundation
import StudyKit

/// Where the game may offer a rewarded ad. Always the player's choice; never shown unasked.
public enum AdPlacement: String, Codable, CaseIterable, Sendable { case revive, bonusXP, cosmeticRoll }

public enum AdOutcome: Sendable {
    /// Watched to the end: grant the reward.
    case rewarded
    /// Closed early: grant nothing.
    case skipped
    /// Could not load or show: grant nothing.
    case failed
}

/// The ad network, kept out of this package. The game supplies the real one; tests use a fake.
public protocol RewardedAdProvider: Sendable {
    func isReady(_ placement: AdPlacement) async -> Bool
    func show(_ placement: AdPlacement) async -> AdOutcome
}

/// What the game is doing right now, from the engine's own state.
public struct AdContext: Sendable {
    /// From StudyKit: the player owns remove-ads or any Nursebook unlock.
    public var adsRemoved: Bool
    /// A patient question is on screen.
    public var questionPending: Bool
    /// The ward clock is paused (pause menu, upgrade choice, background).
    public var clockPaused: Bool

    public init(adsRemoved: Bool, questionPending: Bool = false, clockPaused: Bool = false) {
        self.adsRemoved = adsRemoved; self.questionPending = questionPending; self.clockPaused = clockPaused
    }
}

public enum AdRefusal: Equatable, Sendable {
    case adsRemoved
    case dailyCapReached
    case busy
    /// A recent ad failed; wait before offering again so a broken network never loops.
    case coolingDown
    case notReady
}

/// Decides whether a rewarded ad may be offered and counts the ones shown. All limits are enforced here,
/// on the device, before the ad network is ever asked.
public actor AdGate {
    public static let dailyCap = 5
    public static let failureCooldown: TimeInterval = 60

    struct Tally: Codable, Equatable { var day = 0; var shown = 0 }

    private let provider: RewardedAdProvider
    private let url: URL
    private var tally: Tally
    /// False when the tally file exists but cannot be read: refuse rather than risk exceeding the cap.
    private let readable: Bool
    private var lastFailure: Date?

    public init(directory: URL, provider: RewardedAdProvider) {
        self.provider = provider
        url = directory.appendingPathComponent("ad-tally.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Tally.self, from: $0) }
            tally = saved ?? Tally()
            readable = saved != nil
        } else {
            tally = Tally()
            readable = true
        }
    }

    public func shownToday(now: Date = Date(), utcOffset: Int = TimeZone.current.secondsFromGMT()) -> Int {
        tally.day == StudyEvent.localDay(now, utcOffset: utcOffset) ? tally.shown : 0
    }

    /// Nil means the game may show the offer button.
    public func refusal(for placement: AdPlacement, context: AdContext, now: Date = Date(),
                        utcOffset: Int = TimeZone.current.secondsFromGMT()) async -> AdRefusal? {
        if let local = localRefusal(context: context, now: now, utcOffset: utcOffset) { return local }
        return await provider.isReady(placement) ? nil : .notReady
    }

    /// Shows the ad if every rule allows it. True only when the player watched to the end.
    public func show(_ placement: AdPlacement, context: AdContext, now: Date = Date(),
                     utcOffset: Int = TimeZone.current.secondsFromGMT()) async -> Bool {
        guard localRefusal(context: context, now: now, utcOffset: utcOffset) == nil else { return false }
        // Count before showing: a crash or kill mid-ad must not hand back the slot.
        let day = StudyEvent.localDay(now, utcOffset: utcOffset)
        let before = tally
        tally = Tally(day: day, shown: (tally.day == day ? tally.shown : 0) + 1)
        guard save() else { tally = before; return false }
        switch await provider.show(placement) {
        case .rewarded:
            return true
        case .skipped:
            return false
        case .failed:
            // Nothing was shown, so the slot is returned, but offers pause for a minute.
            tally.shown -= 1
            _ = save()
            lastFailure = now
            return false
        }
    }

    private func localRefusal(context: AdContext, now: Date, utcOffset: Int) -> AdRefusal? {
        if context.adsRemoved { return .adsRemoved }
        if context.questionPending || context.clockPaused { return .busy }
        guard readable, shownToday(now: now, utcOffset: utcOffset) < AdGate.dailyCap else { return .dailyCapReached }
        if let lastFailure, now.timeIntervalSince(lastFailure) < AdGate.failureCooldown, now >= lastFailure { return .coolingDown }
        return nil
    }

    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(tally).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
