import Foundation

/// Every event from both apps and all devices. Merging is order-independent: any two ledgers that have seen
/// the same events are equal.
public struct Ledger: Equatable, Sendable {
    // ponytail: grows without bound (about 5,000 events for a heavy year). Compact old days into totals if it matters.
    public private(set) var events: [UUID: StudyEvent] = [:]

    public init(_ events: [StudyEvent] = []) { for event in events { insert(event) } }

    /// Returns true when the ledger changed.
    @discardableResult
    public mutating func insert(_ event: StudyEvent) -> Bool {
        if let existing = events[event.id] {
            guard existing != event, event.wins(over: existing) else { return false }
        }
        events[event.id] = event
        return true
    }

    /// Returns the IDs that were new or replaced.
    @discardableResult
    public mutating func merge(_ other: some Sequence<StudyEvent>) -> [UUID] {
        other.filter { insert($0) }.map(\.id)
    }

    public var xp: Int { events.values.reduce(0) { $0 + $1.xp } }

    public func xp(from app: StudyApp) -> Int { events.values.lazy.filter { $0.app == app }.reduce(0) { $0 + $1.xp } }

    /// Days in a row with at least one event in either app, ending today or yesterday (so the streak
    /// shows until the day is actually missed).
    public func streak(asOf now: Date = Date(), utcOffset: Int = TimeZone.current.secondsFromGMT()) -> Int {
        let days = Set(events.values.map(\.localDay))
        let today = StudyEvent.localDay(now, utcOffset: utcOffset)
        var day = days.contains(today) ? today : today - 1
        var count = 0
        while days.contains(day) { count += 1; day -= 1 }
        return count
    }

    public func studiedToday(asOf now: Date = Date(), utcOffset: Int = TimeZone.current.secondsFromGMT()) -> Bool {
        let today = StudyEvent.localDay(now, utcOffset: utcOffset)
        return events.values.contains { $0.localDay == today }
    }
}

/// Local copy of the ledger in the shared App Group folder. Each app writes only its own file and reads both,
/// so the two apps never write the same file.
public struct LedgerFiles: Sendable {
    public let directory: URL
    public let app: StudyApp

    public init(directory: URL, app: StudyApp) { self.directory = directory; self.app = app }

    func url(_ app: StudyApp) -> URL { directory.appendingPathComponent("ledger-\(app.rawValue).json") }

    /// Merges both apps' files. A file that cannot be decoded throws; its bytes stay on disk.
    public func load() throws -> Ledger {
        var ledger = Ledger()
        for app in StudyApp.allCases where FileManager.default.fileExists(atPath: url(app).path) {
            ledger.merge(try JSONDecoder().decode([StudyEvent].self, from: Data(contentsOf: url(app))))
        }
        return ledger
    }

    /// Writes everything this app knows to its own file. Overlap with the other app's file is harmless:
    /// loading merges by event ID.
    public func save(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let events = ledger.events.values.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        try JSONEncoder().encode(events).write(to: url(app), options: .atomic)
    }
}
