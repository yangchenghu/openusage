import Foundation
import os
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

/// OpenUsage's own Keychain item for one provider's sign-in (`<bundle id>.signin`, account = provider
/// family). Items the app created never prompt. The bundle-specific service keeps dev and release
/// sign-ins apart, like Cursor's.
///
/// A renewal the Keychain refused to save is kept in memory and served in its place (and its save
/// retried on every read), because the provider may already have spent the refresh token it replaced:
/// falling back to the stored one would turn a Keychain hiccup into a forced re-sign-in.
final class SignedInAccountKeychainStore: SignedInAccountStoring, @unchecked Sendable {
    let service: String
    let account: String
    private let unsaved = OSAllocatedUnfairLock<SignedInAccount?>(initialState: nil)

    init(providerFamily: String, service: String = SignedInAccountKeychainStore.defaultService) {
        self.account = providerFamily
        self.service = service
    }

    static var defaultService: String {
        let environment = ProcessInfo.processInfo.environment
        let containingID = Bundle.main.executableURL.flatMap(ContainingAppBundle.url(for:))
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let bundleID = environment["OPENUSAGE_DEFAULTS_SUITE"]?.nilIfEmpty
            ?? Bundle.main.bundleIdentifier ?? containingID ?? "com.robinebers.openusage"
        return bundleID + ".signin"
    }

    func load() throws -> SignedInAccount? {
        if let pending = unsaved.withLock({ $0 }) {
            try? write(pending)
            return pending
        }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure("read", status) }
        guard let saved = try? JSONDecoder().decode(SignedInAccount.self, from: data), !saved.accessToken.isEmpty else {
            AppLog.error(LogTag.auth(account), "saved sign-in is unreadable")
            throw SignInStoreError.unreadable
        }
        return saved
    }

    func save(_ value: SignedInAccount) throws {
        do {
            try write(value)
        } catch {
            unsaved.withLock { $0 = value }
            throw error
        }
    }

    func delete() throws {
        unsaved.withLock { $0 = nil }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("delete", status) }
    }

    private func write(_ value: SignedInAccount) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure("add", added) }
        } else if status != errSecSuccess {
            throw failure("update", status)
        }
        unsaved.withLock { if $0 == value { $0 = nil } }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func failure(_ operation: String, _ status: OSStatus) -> SignInStoreError {
        AppLog.error(LogTag.auth(account), "sign-in Keychain \(operation) failed (\(status))")
        return .keychain(status)
    }
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
