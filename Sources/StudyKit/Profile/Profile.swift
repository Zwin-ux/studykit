import Foundation

/// What both apps show for the student: an avatar and, if they set one, a name. Stored on the device and in
/// the student's private iCloud database only.
public struct Profile: Codable, Equatable, Sendable {
    public static let nameLimit = 24

    public var avatar: Avatar
    public private(set) var displayName: String?
    public var updatedAt: Date

    public init(avatar: Avatar = Avatar(), displayName: String? = nil, updatedAt: Date = Date()) {
        self.avatar = avatar
        self.displayName = displayName.flatMap(Profile.cleanName)
        self.updatedAt = updatedAt
    }

    /// Trims the name; nil when empty, over 24 characters or holding control characters.
    public static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= nameLimit,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }

    /// Returns false and changes nothing when the name is not allowed. An empty name clears it.
    @discardableResult
    public mutating func setDisplayName(_ raw: String, at date: Date = Date()) -> Bool {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = nil
        } else {
            guard let name = Profile.cleanName(raw) else { return false }
            displayName = name
        }
        updatedAt = date
        return true
    }

    /// Two devices or two apps changed the profile: the newer one wins whole. Equal times keep `self`.
    public func merged(with other: Profile) -> Profile {
        other.updatedAt > updatedAt ? other : self
    }
}

/// Local copy of the profile. Both apps point it at the same App Group folder.
public struct ProfileFile: Sendable {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("profile.json") }

    /// Nil when there is no file yet. A file that cannot be decoded throws; the bytes stay on disk.
    public func load() throws -> Profile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
    }

    public func save(_ profile: Profile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: url, options: .atomic)
    }
}
