import Foundation
import Security

struct CursorAccount: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var label: String = "Cursor Account"

    var authState: CursorAuthState {
        CursorAuthState(accessToken: accessToken, refreshToken: refreshToken, membershipType: nil, source: .openUsage)
    }
}

protocol CursorAccountVault: Sendable {
    func load() async throws -> CursorAccount?
    func save(_ account: CursorAccount) async throws
    func delete() async throws
}

/// Owns only OpenUsage's Cursor login. The bundle-specific service keeps dev/release logins apart.
/// Actor isolation serializes blocking Keychain operations away from the UI executor.
actor CursorKeychainVault: CursorAccountVault {
    let service: String

    init(service: String = CursorKeychainVault.defaultService) {
        self.service = service
    }

    static var defaultService: String {
        let environment = ProcessInfo.processInfo.environment
        let containingID = Bundle.main.executableURL.flatMap(ContainingAppBundle.url(for:))
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let bundleID = environment["OPENUSAGE_DEFAULTS_SUITE"]?.nilIfEmpty
            ?? Bundle.main.bundleIdentifier ?? containingID ?? "com.robinebers.openusage"
        return bundleID + ".cursor-account"
    }

    func load() throws -> CursorAccount? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        guard let account = try? JSONDecoder().decode(CursorAccount.self, from: data),
              !account.accessToken.isEmpty, !account.refreshToken.isEmpty else { throw CursorLoginError.invalidResponse }
        return account
    }

    func save(_ account: CursorAccount) throws {
        let data = try JSONEncoder().encode(account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "cursor"]
    }

    private func failure(_ status: OSStatus) -> CursorLoginError {
        AppLog.error(LogTag.auth("cursor"), "OpenUsage Cursor Keychain operation failed (\(status))")
        return .keychain
    }
}
