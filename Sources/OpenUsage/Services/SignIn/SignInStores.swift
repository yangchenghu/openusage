import Foundation

/// The per-provider OpenUsage sign-in stores. One shared instance per provider, so the auth store a
/// refresh reads and the session the UI drives see the same account — including a renewal held in
/// memory after a failed Keychain write.
struct SignInStores: Sendable {
    let claude: any SignedInAccountStoring
    let codex: any SignedInAccountStoring
    let grok: any SignedInAccountStoring

    static let live = SignInStores(
        claude: SignedInAccountKeychainStore(providerFamily: "claude"),
        codex: SignedInAccountKeychainStore(providerFamily: "codex"),
        grok: SignedInAccountKeychainStore(providerFamily: "grok")
    )
}
