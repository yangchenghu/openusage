import Foundation
import Security

/// An account signed in inside OpenUsage (not borrowed from a CLI): the tokens OpenUsage alone owns
/// and renews, plus a display label (usually the email).
struct SignedInAccount: Codable, Equatable, Sendable {
    /// Keys used in `extras`.
    static let identityKey = "identity"
    static let chatGPTAccountIDKey = "chatgpt_account_id"
    static let idTokenKey = "id_token"

    var label: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// The scope string the provider granted, sent back on renewal so a refresh never asks for more.
    var scopes: String?
    var extras: [String: String] = [:]

    /// Whether the access token is expired or about to be (within `leeway`). Unknown expiry is trusted
    /// until the provider rejects it.
    func needsRenewal(now: Date, leeway: TimeInterval = 5 * 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// The account after a refresh grant: rotated tokens replace the old ones; a provider that doesn't
    /// rotate the refresh token keeps the current one.
    func renewed(with response: OAuthTokenResponse, now: Date) -> SignedInAccount {
        var next = self
        next.accessToken = response.accessToken
        if let refreshToken = response.refreshToken?.nilIfEmpty { next.refreshToken = refreshToken }
        next.expiresAt = response.expiresIn.map { now.addingTimeInterval($0) } ?? ProviderParse.jwtExpiry(response.accessToken)
        if let scope = response.scope?.nilIfEmpty { next.scopes = scope }
        if let idToken = response.idToken?.nilIfEmpty { next.extras[Self.idTokenKey] = idToken }
        return next
    }
}

/// Reads and writes one provider's signed-in account. Blocking (Keychain); call off the main actor.
protocol SignedInAccountStoring: Sendable {
    func load() throws -> SignedInAccount?
    func save(_ account: SignedInAccount) throws
    func delete() throws
}

enum SignInStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .keychain: "Couldn't access OpenUsage's saved sign-in in Keychain. Unlock your Keychain and try again."
        case .unreadable: "OpenUsage's saved sign-in is damaged. Sign in again."
        }
    }
}
