#if canImport(CloudKit)
import CloudKit
import Foundation

/// The student's private iCloud database, one custom zone. Nothing here is visible to us or to anyone else.
/// Needs the iCloud entitlement for `iCloud.com.bonelli.study`; not exercised by package tests.
public struct CloudKitTransport: SyncTransport {
    public static let containerID = "iCloud.com.bonelli.study"
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "Study", ownerName: CKCurrentUserDefaultName)
    private var profileID: CKRecord.ID { CKRecord.ID(recordName: "profile", zoneID: zoneID) }

    public init(containerID: String = CloudKitTransport.containerID) {
        database = CKContainer(identifier: containerID).privateCloudDatabase
    }

    private func ensureZone() async throws {
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    public func upload(events: [StudyEvent]) async throws {
        try await ensureZone()
        let records = events.map { event in
            let record = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID))
            record["kind"] = event.kind.rawValue
            record["app"] = event.app.rawValue
            record["at"] = event.at
            record["utcOffset"] = event.utcOffset
            record["xp"] = event.xp
            record["subject"] = event.subject
            return record
        }
        // CloudKit takes at most 400 records per request.
        for start in stride(from: 0, to: records.count, by: 400) {
            let batch = Array(records[start..<min(start + 400, records.count)])
            let (saved, _) = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys, atomically: false)
            for result in saved.values { _ = try result.get() }
        }
    }

    public func upload(profile: Profile) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: "Profile", recordID: profileID)
        record["avatar"] = profile.avatar.slug
        record["displayName"] = profile.displayName
        record["updatedAt"] = profile.updatedAt
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
        for result in saved.values { _ = try result.get() }
    }

    public func upload(ownership: AppOwnership) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: "Ownership", recordID: CKRecord.ID(recordName: "ownership-\(ownership.app.rawValue)", zoneID: zoneID))
        record["app"] = ownership.app.rawValue
        record["owned"] = ownership.owned.map(\.rawValue).sorted()
        record["checkedAt"] = ownership.checkedAt
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
        for result in saved.values { _ = try result.get() }
    }

    public func fetch() async throws -> RemoteSnapshot {
        try await ensureZone()
        var snapshot = RemoteSnapshot()
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for result in changes.modificationResultsByID.values {
                let record = try result.get().record
                switch record.recordType {
                case "Event": if let event = event(record) { snapshot.events.append(event) }
                case "Profile": snapshot.profile = profile(record)
                case "Ownership": if let ownership = ownership(record) { snapshot.ownership.append(ownership) }
                default: break
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return snapshot
    }

    /// Records that do not parse are skipped, never guessed.
    private func event(_ record: CKRecord) -> StudyEvent? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let kind = (record["kind"] as? String).flatMap(StudyEvent.Kind.init(rawValue:)),
              let app = (record["app"] as? String).flatMap(StudyApp.init(rawValue:)),
              let at = record["at"] as? Date,
              let offset = record["utcOffset"] as? Int,
              let xp = record["xp"] as? Int else { return nil }
        return StudyEvent(id: id, kind: kind, app: app, at: at, utcOffset: offset, xp: xp, subject: record["subject"] as? String)
    }

    private func ownership(_ record: CKRecord) -> AppOwnership? {
        guard let app = (record["app"] as? String).flatMap(StudyApp.init(rawValue:)),
              record.recordID.recordName == "ownership-\(app.rawValue)",
              let owned = record["owned"] as? [String],
              let checkedAt = record["checkedAt"] as? Date else { return nil }
        return AppOwnership(app: app, owned: Set(owned.compactMap(StudyProduct.init(rawValue:))), checkedAt: checkedAt)
    }

    private func profile(_ record: CKRecord) -> Profile? {
        guard let avatar = (record["avatar"] as? String).flatMap(Avatar.init(slug:)),
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        return Profile(avatar: avatar, displayName: record["displayName"] as? String, updatedAt: updatedAt)
    }
}
#endif
