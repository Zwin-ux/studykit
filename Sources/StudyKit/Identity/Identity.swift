import Foundation

/// The signed-in student. `id` is Apple's stable user identifier for our team; we request no name and no email.
public struct StudyUser: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public enum CredentialState: Sendable { case authorized, revoked, notFound }

/// Performs the sign-in and answers whether a stored user is still valid. Apple's implementation is in
/// `AppleIdentityProvider`; tests use a fake.
public protocol IdentityProvider: Sendable {
    func signIn() async throws -> StudyUser
    func credentialState(for user: StudyUser) async -> CredentialState
}

/// Where the user identifier is kept between launches. Shared by both apps through one Keychain access group.
public protocol CredentialStore: Sendable {
    func load() throws -> StudyUser?
    func save(_ user: StudyUser) throws
    func clear() throws
}

public enum IdentityState: Equatable, Sendable {
    case signedOut
    case signedIn(StudyUser)
}

/// One account for both apps. Call `restore()` at launch, `signIn()` from the first-run screen.
public actor Identity {
    public private(set) var state: IdentityState = .signedOut
    /// Owner decision 12 Nov 2026: an account is required. Flip to false if App Review objects (guideline 5.1.1(v)).
    public let requireAccount: Bool
    private let provider: IdentityProvider
    private let store: CredentialStore

    public init(provider: IdentityProvider, store: CredentialStore, requireAccount: Bool = true) {
        self.provider = provider
        self.store = store
        self.requireAccount = requireAccount
    }

    /// True when the app must show sign-in before anything else.
    public var needsSignIn: Bool { requireAccount && state == .signedOut }

    /// Reads the stored user and checks Apple still honours it. A revoked credential signs the student out.
    /// A store that cannot be read leaves the student signed out without erasing anything.
    @discardableResult
    public func restore() async -> IdentityState {
        guard let user = try? store.load() else { state = .signedOut; return state }
        switch await provider.credentialState(for: user) {
        case .authorized:
            state = .signedIn(user)
        case .revoked, .notFound:
            try? store.clear()
            state = .signedOut
        }
        return state
    }

    @discardableResult
    public func signIn() async throws -> StudyUser {
        let user = try await provider.signIn()
        try store.save(user)
        state = .signedIn(user)
        return user
    }

    public func signOut() throws {
        try store.clear()
        state = .signedOut
    }
}

/// For tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var user: StudyUser?
    public init(user: StudyUser? = nil) { self.user = user }
    public func load() throws -> StudyUser? { lock.withLock { user } }
    public func save(_ user: StudyUser) throws { lock.withLock { self.user = user } }
    public func clear() throws { lock.withLock { user = nil } }
}
