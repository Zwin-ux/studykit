# StudyKit

Shared engine for Nursebook and One More Shift: one account, one avatar, shared progress.
Spec: https://github.com/Zwin-ux/nursebook/issues/297

| Module | Status | Issue |
|---|---|---|
| Identity (Sign in with Apple, shared Keychain) | built, unit tested with fakes | Zwin-ux/nursebook#298 |
| Profile (avatar, display name) | built, unit tested | Zwin-ux/nursebook#298 |
| Ledger (events, XP, streak) + Sync (offline queue, merge) | built, unit tested against an in-memory transport; `CloudKitTransport` compiles but is untested | Zwin-ux/nursebook#300 |
| Entitlements | not started | Zwin-ux/nursebook#301 |
| StudyLink | not started (moves from both apps) | Zwin-ux/nursebook#302 |
| AdGate (separate target, game only) | not started | Zwin-ux/nursebook#304 |

`swift test` runs everything. `KeychainCredentialStore`, `AppleIdentityProvider` and `CloudKitTransport` need a signed app with the
entitlements from Zwin-ux/nursebook#299 and are not covered by package tests.

Rules: no third-party dependencies, no analytics, no network code outside Sync, no ad code in the `StudyKit` target.
