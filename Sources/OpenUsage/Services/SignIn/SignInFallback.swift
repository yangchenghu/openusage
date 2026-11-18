import Foundation
import os

/// Whether a card (Claude, Codex, Grok) is currently using its OpenUsage sign-in. The tool's own login
/// on this Mac comes first: every refresh starts on it and switches here only when it finds no working
/// login and a sign-in is saved. Shared by reference, so the reset claim and grants read the source the
/// last refresh settled on.
final class SignInFallback: Sendable {
    private let active: OSAllocatedUnfairLock<Bool>

    init(active: Bool = false) {
        self.active = OSAllocatedUnfairLock(initialState: active)
    }

    var isActive: Bool { active.withLock { $0 } }

    func set(_ value: Bool) {
        active.withLock { $0 = value }
    }

    /// Whether a refresh on the local login ended with no working login — the only case the sign-in
    /// steps in. Network and server failures keep the local result.
    static func localLoginMissing(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.errorCategory == .notLoggedIn || snapshot.errorCategory == .authExpired
    }
}
