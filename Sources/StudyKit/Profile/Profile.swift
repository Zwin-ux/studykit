import Foundation

/// Which words game text uses for the student. Separate from the avatar: it never changes the body.
public enum Pronouns: String, Codable, CaseIterable, Sendable { case they, she, he }

/// What both apps show for the student: an avatar and, if they set one, a name. Stored on the device and in
/// the student's private iCloud database only.
public struct Profile: Codable, Equatable, Sendable {
    public static let nameLimit = 24

    /// The avatar exactly as stored. A newer app can write options this build does not know; keeping the raw
    /// slug means an older build shows its default nurse but never overwrites the newer choice.
    public private(set) var avatarSlug: String
    public private(set) var displayName: String?
    public var pronouns: Pronouns
    public var updatedAt: Date

    public init(avatar: Avatar = Avatar(), displayName: String? = nil, pronouns: Pronouns = .they, updatedAt: Date = Date()) {
        self.init(avatarSlug: avatar.slug, displayName: displayName, pronouns: pronouns, updatedAt: updatedAt)
    }

    public init(avatarSlug: String, displayName: String? = nil, pronouns: Pronouns = .they, updatedAt: Date = Date()) {
        self.avatarSlug = avatarSlug
        self.displayName = displayName.flatMap(Profile.cleanName)
        self.pronouns = pronouns
        self.updatedAt = updatedAt
    }

    /// The avatar to draw: the stored one, or the default when this build cannot read it.
    public var avatar: Avatar {
        get { Avatar(slug: avatarSlug) ?? Avatar() }
        set { avatarSlug = newValue.slug }
    }

    private enum CodingKeys: String, CodingKey { case avatar, displayName, pronouns, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let slug = try? values.decode(String.self, forKey: .avatar) {
            avatarSlug = slug
        } else {
            avatarSlug = try values.decode(Avatar.self, forKey: .avatar).slug // files written before slugs
        }
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        // An unknown pronoun from a newer build reads as the neutral default.
        pronouns = (try? values.decodeIfPresent(Pronouns.self, forKey: .pronouns)) ?? .they
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(avatarSlug, forKey: .avatar)
        try values.encodeIfPresent(displayName, forKey: .displayName)
        try values.encode(pronouns, forKey: .pronouns)
        try values.encode(updatedAt, forKey: .updatedAt)
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
