import Foundation

/// Everything sold across the two apps. All are one-time purchases (prices frozen 12 Nov 2026).
public enum StudyProduct: String, Codable, CaseIterable, Sendable {
    /// Nursebook: the full textbook, $14.99.
    case book = "com.bonelli.nursebook.fundamentals.full"
    /// Nursebook: timed TEAS 7 / HESI A2 sections, $14.99.
    case exams = "com.bonelli.nursebook.entrance.full"
    /// Nursebook: both of the above, $24.99.
    case bundle = "com.bonelli.nursebook.bundle.full"
    /// One More Shift: no rewarded-ad offers, $3.99.
    case removeAds = "com.bonelli.onemoreshift.removeads"

    public var app: StudyApp { self == .removeAds ? .oneMoreShift : .nursebook }
}

/// What Nursebook unlocks. Built ONLY from the purchases StoreKit reports to Nursebook itself; synced flags
/// from the other app can never produce one of these.
public struct StudyAccess: Equatable, Sendable {
    public let book: Bool
    public let exams: Bool

    public init(owned: Set<StudyProduct>) {
        book = owned.contains(.book) || owned.contains(.bundle)
        exams = owned.contains(.exams) || owned.contains(.bundle)
    }
}

/// What one app's StoreKit said it owns, the last time that app checked. Each app writes only its own record.
/// It is a statement of current state, not a history: a refund produces a newer record without the product.
public struct AppOwnership: Codable, Equatable, Sendable {
    public let app: StudyApp
    public let owned: Set<StudyProduct>
    public let checkedAt: Date

    /// Products that belong to another app are dropped: an app can only vouch for its own purchases.
    public init(app: StudyApp, owned: Set<StudyProduct>, checkedAt: Date = Date()) {
        self.app = app
        self.owned = owned.filter { $0.app == app }
        self.checkedAt = checkedAt
    }

    public func merged(with other: AppOwnership) -> AppOwnership {
        other.app == app && other.checkedAt > checkedAt ? other : self
    }
}

/// Both apps' records. The only cross-app effect is `adsRemoved`.
public struct OwnershipFlags: Equatable, Sendable {
    public private(set) var records: [StudyApp: AppOwnership] = [:]

    public init(_ records: [AppOwnership] = []) { for record in records { merge(record) } }

    /// Returns true when the record was newer than what we had.
    @discardableResult
    public mutating func merge(_ record: AppOwnership) -> Bool {
        let merged = records[record.app]?.merged(with: record) ?? record
        guard merged != records[record.app] else { return false }
        records[record.app] = merged
        return true
    }

    /// The game shows no ad offers when its own remove-ads is owned, or when the student owns any Nursebook unlock.
    public var adsRemoved: Bool {
        records[.oneMoreShift]?.owned.contains(.removeAds) == true || !(records[.nursebook]?.owned.isEmpty ?? true)
    }
}

/// Where an app learns what it owns. `StoreKitPurchaseSource` is the real one.
public protocol PurchaseSource: Sendable {
    func currentEntitlements() async -> Set<StudyProduct>
}

/// Local copies in the shared App Group folder: each app writes its own file and reads both, so a Nursebook
/// purchase removes game ads on the same device even with iCloud off.
public struct OwnershipFiles: Sendable {
    public let directory: URL
    public let app: StudyApp

    public init(directory: URL, app: StudyApp) { self.directory = directory; self.app = app }

    func url(_ app: StudyApp) -> URL { directory.appendingPathComponent("ownership-\(app.rawValue).json") }

    public func load() throws -> OwnershipFlags {
        var flags = OwnershipFlags()
        for app in StudyApp.allCases where FileManager.default.fileExists(atPath: url(app).path) {
            let record = try JSONDecoder().decode(AppOwnership.self, from: Data(contentsOf: url(app)))
            // A file is only trusted for the app it is named after.
            if record.app == app { flags.merge(record) }
        }
        return flags
    }

    public func save(_ record: AppOwnership) throws {
        guard record.app == app else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url(app), options: .atomic)
    }
}
