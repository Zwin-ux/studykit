import Foundation

/// Everything in the student's private iCloud database.
public struct RemoteSnapshot: Sendable {
    public var events: [StudyEvent]
    public var profile: Profile?
    public init(events: [StudyEvent] = [], profile: Profile? = nil) { self.events = events; self.profile = profile }
}

/// The remote side. `CloudKitTransport` is the real one; tests use an in-memory fake.
public protocol SyncTransport: Sendable {
    func upload(events: [StudyEvent]) async throws
    func upload(profile: Profile) async throws
    // ponytail: fetches everything each time. Move to change tokens when a ledger passes a few thousand events.
    func fetch() async throws -> RemoteSnapshot
}

public enum SyncState: Equatable, Sendable {
    case never
    case synced(Date)
    /// iCloud is off or unreachable. The apps stay fully usable; changes wait in the queue.
    case paused
}

/// What the engine keeps on disk between launches, beside the ledger files.
struct SyncQueue: Codable, Equatable {
    var pendingEvents: Set<UUID> = []
    var profilePending = false
}

/// Owns the ledger and profile for one app, saves them locally first, and syncs when it can.
public actor SyncEngine {
    public private(set) var ledger: Ledger
    public private(set) var profile: Profile?
    public private(set) var state: SyncState = .never
    private var queue: SyncQueue
    private let transport: SyncTransport
    private let ledgerFiles: LedgerFiles
    private let profileFile: ProfileFile
    private let queueURL: URL

    /// Loads local state. A missing folder starts empty; an unreadable file throws and nothing is overwritten.
    public init(directory: URL, app: StudyApp, transport: SyncTransport) throws {
        self.transport = transport
        ledgerFiles = LedgerFiles(directory: directory, app: app)
        profileFile = ProfileFile(directory: directory)
        queueURL = directory.appendingPathComponent("sync-queue-\(app.rawValue).json")
        ledger = try ledgerFiles.load()
        profile = try profileFile.load()
        queue = FileManager.default.fileExists(atPath: queueURL.path)
            ? try JSONDecoder().decode(SyncQueue.self, from: Data(contentsOf: queueURL)) : SyncQueue()
    }

    public var pendingCount: Int { queue.pendingEvents.count + (queue.profilePending ? 1 : 0) }

    /// Saves the event on this device, then queues it. Returns false when it was already counted.
    @discardableResult
    public func record(_ event: StudyEvent) throws -> Bool {
        guard ledger.insert(event) else { return false }
        queue.pendingEvents.insert(event.id)
        try save()
        return true
    }

    public func setProfile(_ new: Profile) throws {
        profile = new
        queue.profilePending = true
        try save()
    }

    /// Uploads what is waiting, then pulls and merges. On any failure the queue is kept and the state is paused.
    @discardableResult
    public func sync(now: Date = Date()) async -> SyncState {
        do {
            let waiting = queue.pendingEvents.compactMap { ledger.events[$0] }
            if !waiting.isEmpty { try await transport.upload(events: waiting) }
            queue.pendingEvents.subtract(waiting.map(\.id))
            // IDs with no event left (replaced by a winning duplicate) have nothing to send.
            queue.pendingEvents = queue.pendingEvents.filter { ledger.events[$0] != nil }

            if queue.profilePending, let profile { try await transport.upload(profile: profile) }
            queue.profilePending = false

            let remote = try await transport.fetch()
            ledger.merge(remote.events)
            if let theirs = remote.profile {
                let merged = profile?.merged(with: theirs) ?? theirs
                // Ours was newer than the server's copy: send it next time.
                if merged != theirs { queue.profilePending = true }
                profile = merged
            } else if profile != nil {
                queue.profilePending = true
            }
            try save()
            state = .synced(now)
        } catch {
            try? save()
            state = .paused
        }
        return state
    }

    private func save() throws {
        try ledgerFiles.save(ledger)
        if let profile { try profileFile.save(profile) }
        try JSONEncoder().encode(queue).write(to: queueURL, options: .atomic)
    }
}
