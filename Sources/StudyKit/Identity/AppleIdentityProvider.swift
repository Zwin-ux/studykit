#if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
import AuthenticationServices
import Foundation

/// Sign in with Apple, requesting no scopes: we receive the user identifier only (no name, no email).
public final class AppleIdentityProvider: NSObject, IdentityProvider, @unchecked Sendable {
    public enum Failure: Error { case noCredential }

    public override init() {}

    @MainActor
    public func signIn() async throws -> StudyUser {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let delegate = Delegate()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = delegate
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            // The controller is retained by the delegate for the length of the request.
            delegate.controller = controller
            controller.performRequests()
        }
    }

    public func credentialState(for user: StudyUser) async -> CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: user.id) { state, _ in
                switch state {
                case .authorized: continuation.resume(returning: .authorized)
                case .revoked: continuation.resume(returning: .revoked)
                default: continuation.resume(returning: .notFound)
                }
            }
        }
    }

    private final class Delegate: NSObject, ASAuthorizationControllerDelegate {
        var continuation: CheckedContinuation<StudyUser, Error>?
        var controller: ASAuthorizationController?

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            defer { self.controller = nil }
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                continuation?.resume(throwing: Failure.noCredential); continuation = nil; return
            }
            continuation?.resume(returning: StudyUser(id: credential.user)); continuation = nil
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
            self.controller = nil
        }
    }
}
#endif
