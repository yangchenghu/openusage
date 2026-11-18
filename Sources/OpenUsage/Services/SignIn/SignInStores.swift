import Foundation

/// The per-provider OpenUsage sign-in stores, all backed by the one shared `SignInVault`, so the auth
/// store a refresh reads and the session the UI drives see the same account — including a renewal held
/// in memory after a failed Keychain write.
struct SignInStores: Sendable {
    let claude: any SignedInAccountStoring
    let codex: any SignedInAccountStoring
    let grok: any SignedInAccountStoring
    let cursor: any CursorAccountVault

    static let live = SignInStores(vault: .shared)

    init(vault: SignInVault) {
        claude = SignInVaultAccountStore(vault: vault, family: "claude")
        codex = SignInVaultAccountStore(vault: vault, family: "codex")
        grok = SignInVaultAccountStore(vault: vault, family: "grok")
        cursor = CursorSignInVault(vault: vault)
    }
}
