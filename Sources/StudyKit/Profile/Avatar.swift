import Foundation

/// The student's nurse. Values mirror `CharacterAppearance.swift` in One More Shift; the raw values are the
/// names both apps and the design kit use. Appearance only: it never implies a credential.
public struct Avatar: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case ponytail, bun }
    // Raw values are stored in slugs and CloudKit: never rename one, only add. Order is picker order, lightest first.
    // Tint hex values live with the art (One More Shift `CharacterAppearance.swift`, design kit `tokens.json`).
    public enum Skin: String, Codable, CaseIterable, Sendable { case fair, light, warm, tan, deep, rich, umber }
    public enum Hair: String, Codable, CaseIterable, Sendable { case black, darkBrown, brown, auburn, blonde, silver, plum }
    public enum Scrubs: String, Codable, CaseIterable, Sendable { case teal, lavender, navy, sage, wine, black }
    public enum Shoes: String, Codable, CaseIterable, Sendable { case cream, coral, white, black }

    public var shape: Shape
    public var skin: Skin
    public var hair: Hair
    public var scrubs: Scrubs
    public var shoes: Shoes

    public init(shape: Shape = .ponytail, skin: Skin = .warm, hair: Hair = .plum, scrubs: Scrubs = .teal, shoes: Shoes = .cream) {
        self.shape = shape; self.skin = skin; self.hair = hair; self.scrubs = scrubs; self.shoes = shoes
    }

    /// Stable name, e.g. `ponytail-warm-plum-teal-cream`. Asset files and CloudKit use it.
    public var slug: String { [shape.rawValue, skin.rawValue, hair.rawValue, scrubs.rawValue, shoes.rawValue].joined(separator: "-") }

    /// The head asset shows no shoes, so heads are named without them.
    public var headSlug: String { [shape.rawValue, skin.rawValue, hair.rawValue, scrubs.rawValue].joined(separator: "-") }

    public init?(slug: String) {
        let parts = slug.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              let shape = Shape(rawValue: parts[0]), let skin = Skin(rawValue: parts[1]),
              let hair = Hair(rawValue: parts[2]), let scrubs = Scrubs(rawValue: parts[3]),
              let shoes = Shoes(rawValue: parts[4]) else { return nil }
        self.init(shape: shape, skin: skin, hair: hair, scrubs: scrubs, shoes: shoes)
    }

    /// Every combination, in picker order.
    public static let all: [Avatar] = Shape.allCases.flatMap { shape in
        Skin.allCases.flatMap { skin in
            Hair.allCases.flatMap { hair in
                Scrubs.allCases.flatMap { scrubs in
                    Shoes.allCases.map { Avatar(shape: shape, skin: skin, hair: hair, scrubs: scrubs, shoes: $0) }
                }
            }
        }
    }
}
