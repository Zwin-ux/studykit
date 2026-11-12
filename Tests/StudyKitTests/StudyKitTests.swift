import XCTest
@testable import StudyKit

private struct FakeProvider: IdentityProvider {
    var user: StudyUser? = StudyUser(id: "apple-1")
    var credential: CredentialState = .authorized
    struct Cancelled: Error {}
    func signIn() async throws -> StudyUser {
        guard let user else { throw Cancelled() }
        return user
    }
    func credentialState(for user: StudyUser) async -> CredentialState { credential }
}

private struct BrokenStore: CredentialStore {
    struct Unreadable: Error {}
    func load() throws -> StudyUser? { throw Unreadable() }
    func save(_ user: StudyUser) throws { throw Unreadable() }
    func clear() throws { throw Unreadable() }
}

final class IdentityTests: XCTestCase {
    func testFreshInstallNeedsSignInThenKeepsTheUser() async throws {
        let store = InMemoryCredentialStore()
        let identity = Identity(provider: FakeProvider(), store: store)
        await identity.restore()
        let needs = await identity.needsSignIn
        XCTAssertTrue(needs)

        let user = try await identity.signIn()
        XCTAssertEqual(user, StudyUser(id: "apple-1"))
        XCTAssertEqual(try store.load(), user)
        let after = await identity.needsSignIn
        XCTAssertFalse(after)
    }

    func testRestoreSignsInAStoredAuthorizedUser() async {
        let identity = Identity(provider: FakeProvider(), store: InMemoryCredentialStore(user: StudyUser(id: "apple-1")))
        let state = await identity.restore()
        XCTAssertEqual(state, .signedIn(StudyUser(id: "apple-1")))
    }

    func testRevokedCredentialSignsOutAndClearsTheStore() async throws {
        for credential in [CredentialState.revoked, .notFound] {
            let store = InMemoryCredentialStore(user: StudyUser(id: "apple-1"))
            let identity = Identity(provider: FakeProvider(credential: credential), store: store)
            let state = await identity.restore()
            XCTAssertEqual(state, .signedOut)
            XCTAssertNil(try store.load())
        }
    }

    func testCancelledSignInLeavesTheStudentSignedOut() async {
        let store = InMemoryCredentialStore()
        let identity = Identity(provider: FakeProvider(user: nil), store: store)
        do { _ = try await identity.signIn(); XCTFail("sign-in should throw") } catch {}
        let state = await identity.state
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try? store.load())
    }

    func testFailedSaveDoesNotClaimASignIn() async {
        let identity = Identity(provider: FakeProvider(), store: BrokenStore())
        do { _ = try await identity.signIn(); XCTFail("save should throw") } catch {}
        let state = await identity.state
        XCTAssertEqual(state, .signedOut)
    }

    func testUnreadableStoreRestoresSignedOut() async {
        let identity = Identity(provider: FakeProvider(), store: BrokenStore())
        let state = await identity.restore()
        XCTAssertEqual(state, .signedOut)
    }

    func testSignOutClearsTheStore() async throws {
        let store = InMemoryCredentialStore()
        let identity = Identity(provider: FakeProvider(), store: store)
        _ = try await identity.signIn()
        try await identity.signOut()
        XCTAssertNil(try store.load())
        let state = await identity.state
        XCTAssertEqual(state, .signedOut)
    }

    func testOptionalAccountNeverBlocks() async {
        let identity = Identity(provider: FakeProvider(), store: InMemoryCredentialStore(), requireAccount: false)
        await identity.restore()
        let needs = await identity.needsSignIn
        XCTAssertFalse(needs)
    }
}

final class ProfileTests: XCTestCase {
    func testEveryAvatarHasAUniqueSlugThatRoundTrips() {
        XCTAssertEqual(Avatar.all.count, 144)
        XCTAssertEqual(Set(Avatar.all.map(\.slug)).count, 144)
        XCTAssertEqual(Set(Avatar.all.map(\.headSlug)).count, 72)
        for avatar in Avatar.all { XCTAssertEqual(Avatar(slug: avatar.slug), avatar) }
    }

    func testBadSlugsAreRejected() {
        for slug in ["", "ponytail-warm-plum-teal", "ponytail-warm-plum-teal-cream-x", "bob-warm-plum-teal-cream", "ponytail--plum-teal-cream"] {
            XCTAssertNil(Avatar(slug: slug), slug)
        }
    }

    func testNamesAreTrimmedAndBounded() {
        XCTAssertEqual(Profile.cleanName("  Maya \n"), "Maya")
        XCTAssertNil(Profile.cleanName("   "))
        XCTAssertNil(Profile.cleanName(String(repeating: "a", count: 25)))
        XCTAssertNotNil(Profile.cleanName(String(repeating: "a", count: 24)))
        XCTAssertNil(Profile.cleanName("Ma\u{0007}ya"))
        XCTAssertNil(Profile(displayName: "\u{0000}").displayName)
    }

    func testSetDisplayNameRejectsWithoutChanging() {
        let start = Date(timeIntervalSince1970: 100)
        var profile = Profile(displayName: "Maya", updatedAt: start)
        XCTAssertFalse(profile.setDisplayName(String(repeating: "x", count: 40), at: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(profile.displayName, "Maya")
        XCTAssertEqual(profile.updatedAt, start)
        XCTAssertTrue(profile.setDisplayName("  ", at: Date(timeIntervalSince1970: 300)))
        XCTAssertNil(profile.displayName)
        XCTAssertEqual(profile.updatedAt, Date(timeIntervalSince1970: 300))
    }

    func testMergeKeepsTheNewerProfile() {
        let old = Profile(avatar: Avatar(hair: .black), updatedAt: Date(timeIntervalSince1970: 100))
        let new = Profile(avatar: Avatar(hair: .silver), updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(old.merged(with: new), new)
        XCTAssertEqual(new.merged(with: old), new)
        let tie = Profile(avatar: Avatar(shape: .bun), updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(old.merged(with: tie), old)
    }

    func testProfileFileRoundTripsAndKeepsUnreadableBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ProfileFile(directory: dir)
        XCTAssertNil(try file.load())
        let profile = Profile(avatar: Avatar(shape: .bun, skin: .deep), displayName: "Sam", updatedAt: Date(timeIntervalSince1970: 5))
        try file.save(profile)
        XCTAssertEqual(try file.load(), profile)

        try Data("not json".utf8).write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), Data("not json".utf8))
    }
}
