import Foundation

public enum StudyApp: String, Codable, CaseIterable, Sendable { case nursebook, oneMoreShift }

/// One thing the student did. Events are only ever added; XP and streak are worked out from them.
public struct StudyEvent: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case sectionRead, drillDone, examDone, shiftDone }
    public static let xpLimit = 200
    public static let subjectLimit = 80

    public let id: UUID
    public let kind: Kind
    public let app: StudyApp
    public let at: Date
    /// Seconds east of UTC where the student was. The streak counts the day as they lived it,
    /// so travel and daylight saving never break or double a day.
    public let utcOffset: Int
    /// Decided by the producing app's own rules (ShiftCore for a shift), clamped to 0...200.
    public let xp: Int
    /// Section ID, drill subject or exam section; nil for a shift.
    public let subject: String?

    public init(id: UUID = UUID(), kind: Kind, app: StudyApp, at: Date = Date(),
                utcOffset: Int = TimeZone.current.secondsFromGMT(), xp: Int? = nil, subject: String? = nil) {
        self.id = id
        self.kind = kind
        self.app = app
        self.at = at
        self.utcOffset = max(-14 * 3600, min(14 * 3600, utcOffset))
        self.xp = max(0, min(StudyEvent.xpLimit, xp ?? StudyEvent.defaultXP(kind)))
        self.subject = subject.map { String($0.prefix(StudyEvent.subjectLimit)) }
    }

    public static func defaultXP(_ kind: Kind) -> Int {
        switch kind {
        case .sectionRead: 5
        case .drillDone: 10
        case .examDone: 25
        case .shiftDone: 10
        }
    }

    /// The student's calendar day for this event, as whole days since 1970 in their local time.
    public var localDay: Int { StudyEvent.localDay(at, utcOffset: utcOffset) }

    public static func localDay(_ date: Date, utcOffset: Int) -> Int {
        Int(((date.timeIntervalSince1970 + Double(utcOffset)) / 86_400).rounded(.down))
    }

    /// An event that can happen once per subject per day (reading a section): the same subject on the same
    /// local day always gets the same ID, on any device, so repeats collapse to one.
    public static func oncePerDay(_ kind: Kind, app: StudyApp, subject: String, at: Date = Date(),
                                  utcOffset: Int = TimeZone.current.secondsFromGMT(), xp: Int? = nil) -> StudyEvent {
        let day = localDay(at, utcOffset: utcOffset)
        return StudyEvent(id: stableID("\(kind.rawValue)|\(subject)|\(day)"), kind: kind, app: app, at: at,
                          utcOffset: utcOffset, xp: xp, subject: subject)
    }

    /// Deterministic UUID from text (two FNV-1a 64-bit passes). Naming only, not security.
    static func stableID(_ text: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
            return hash
        }
        let a = fnv(0xCBF2_9CE4_8422_2325), b = fnv(0x8422_2325_CBF2_9CE4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((a >> (8 * UInt64(i))) & 0xFF); bytes[8 + i] = UInt8((b >> (8 * UInt64(i))) & 0xFF) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Two different events under one ID (a bug or a tampered file): every device must pick the same one.
    func wins(over other: StudyEvent) -> Bool {
        if at != other.at { return at < other.at }
        if xp != other.xp { return xp < other.xp }
        if kind != other.kind { return kind.rawValue < other.kind.rawValue }
        if app != other.app { return app.rawValue < other.app.rawValue }
        if utcOffset != other.utcOffset { return utcOffset < other.utcOffset }
        return (subject ?? "") <= (other.subject ?? "")
    }
}
