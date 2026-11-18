import Foundation
import Security

/// Every sign-in OpenUsage owns (Claude, Codex, Grok, Cursor) in one Keychain item, so a launch reads
/// the Keychain once instead of once per provider.
struct SignInVaultContents: Codable, Equatable, Sendable {
    /// OpenUsage sign-ins keyed by provider family (`claude`, `codex`, `grok`).
    var accounts: [String: SignedInAccount] = [:]
    var cursor: CursorAccount?
}

/// OpenUsage's single sign-in Keychain item (`<bundle id>.signin`, account `all`). Items the app created
/// never prompt; the bundle-specific service keeps dev and release sign-ins apart.
///
/// The item is read once and then served from memory: only OpenUsage writes it. A write the Keychain
/// refused stays in memory (and is retried on the next access), because it may carry a renewal whose
/// old refresh token the provider already spent — falling back to the stored copy would turn a Keychain
/// hiccup into a forced re-sign-in.
///
/// The first launch with this item moves the older per-provider items into it and deletes them.
final class SignInVault: @unchecked Sendable {
    static let shared = SignInVault()

    let service: String
    private let legacyCursorService: String
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var contents: SignInVaultContents?
        /// Set while memory holds changes the Keychain hasn't accepted yet.
        var unsaved = false
        /// Legacy items read into memory, deleted once the combined item is saved.
        var migrated: [LegacyItem] = []
    }

    private struct LegacyItem: Equatable {
        let service: String
        let account: String
    }

    private static let account = "all"
    private static let legacyFamilies = ["claude", "codex", "grok"]

    init(service: String = SignInVault.defaultService, legacyCursorService: String = SignInVault.defaultLegacyCursorService) {
        self.service = service
        self.legacyCursorService = legacyCursorService
    }

    static var defaultService: String { bundleID + ".signin" }
    static var defaultLegacyCursorService: String { bundleID + ".cursor-account" }

    private static var bundleID: String {
        let environment = ProcessInfo.processInfo.environment
        let containingID = Bundle.main.executableURL.flatMap(ContainingAppBundle.url(for:))
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return environment["OPENUSAGE_DEFAULTS_SUITE"]?.nilIfEmpty
            ?? Bundle.main.bundleIdentifier ?? containingID ?? "com.robinebers.openusage"
    }

    /// Blocking (Keychain) on the first call only; call off the main actor.
    func load() throws -> SignInVaultContents {
        lock.lock()
        defer { lock.unlock() }
        let contents = try loaded(&state)
        if state.unsaved { try? persist(&state) }
        return contents
    }

    /// Applies `change` and saves the whole item. On a Keychain failure the change still takes effect
    /// in memory and the error is thrown.
    func update(_ change: (inout SignInVaultContents) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var contents = try loaded(&state)
        change(&contents)
        state.contents = contents
        state.unsaved = true
        try persist(&state)
    }

    private func loaded(_ state: inout State) throws -> SignInVaultContents {
        if let contents = state.contents { return contents }
        if let data = try read(service: service, account: Self.account) {
            guard let contents = try? JSONDecoder().decode(SignInVaultContents.self, from: data) else {
                AppLog.error(.keychain, "saved OpenUsage sign-ins are unreadable")
                throw SignInStoreError.unreadable
            }
            state.contents = contents
            return contents
        }
        let contents = try migrateLegacyItems(&state)
        state.contents = contents
        return contents
    }

    /// Reads the per-provider items older builds saved. A read that fails keeps its item and leaves the
    /// combined item unsaved, so the next launch tries the move again (unless a sign-in change saves the
    /// combined item first) instead of deleting that sign-in.
    private func migrateLegacyItems(_ state: inout State) throws -> SignInVaultContents {
        var contents = SignInVaultContents()
        var migrated: [LegacyItem] = []
        var failed = false
        for family in Self.legacyFamilies {
            do {
                guard let data = try read(service: service, account: family) else { continue }
                migrated.append(LegacyItem(service: service, account: family))
                if let account = try? JSONDecoder().decode(SignedInAccount.self, from: data), !account.accessToken.isEmpty {
                    contents.accounts[family] = account
                } else {
                    AppLog.error(LogTag.auth(family), "older saved sign-in is unreadable; dropping it")
                }
            } catch {
                failed = true
            }
        }
        do {
            if let data = try read(service: legacyCursorService, account: "cursor") {
                migrated.append(LegacyItem(service: legacyCursorService, account: "cursor"))
                if let account = try? JSONDecoder().decode(CursorAccount.self, from: data),
                   !account.accessToken.isEmpty, !account.refreshToken.isEmpty {
                    contents.cursor = account
                } else {
                    AppLog.error(LogTag.auth("cursor"), "older saved sign-in is unreadable; dropping it")
                }
            }
        } catch {
            failed = true
        }
        state.migrated = migrated
        guard !migrated.isEmpty else { return contents }
        AppLog.info(.keychain, "moving \(migrated.count) older sign-in item(s) into one Keychain item")
        state.contents = contents
        if failed {
            AppLog.error(.keychain, "some older sign-ins couldn't be read; retrying the move next launch")
        } else {
            state.unsaved = true
            try? persist(&state)
        }
        return contents
    }

    private func persist(_ state: inout State) throws {
        guard let contents = state.contents else { return }
        try write(JSONEncoder().encode(contents))
        state.unsaved = false
        for item in state.migrated {
            let status = SecItemDelete(query(service: item.service, account: item.account) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                AppLog.error(.keychain, "couldn't delete an older sign-in item (\(status))")
            }
        }
        state.migrated = []
    }

    private func read(service: String, account: String) throws -> Data? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure("read", status) }
        return data
    }

    private func write(_ data: Data) throws {
        let base = query(service: service, account: Self.account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure("add", added) }
        } else if status != errSecSuccess {
            throw failure("update", status)
        }
    }

    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func failure(_ operation: String, _ status: OSStatus) -> SignInStoreError {
        AppLog.error(.keychain, "sign-in Keychain \(operation) failed (\(status))")
        return .keychain(status)
    }
}

/// One provider's sign-in inside the shared `SignInVault`.
struct SignInVaultAccountStore: SignedInAccountStoring {
    let vault: SignInVault
    let family: String

    func load() throws -> SignedInAccount? {
        try vault.load().accounts[family]
    }

    func save(_ account: SignedInAccount) throws {
        try vault.update { $0.accounts[family] = account }
    }

    func delete() throws {
        try vault.update { $0.accounts[family] = nil }
    }
}

/// OpenUsage's Cursor login inside the shared `SignInVault`.
struct CursorSignInVault: CursorAccountVault {
    let vault: SignInVault

    func load() async throws -> CursorAccount? {
        try await loadOffMainActor { [vault] in try vault.load().cursor }
    }

    func save(_ account: CursorAccount) async throws {
        try await loadOffMainActor { [vault] in try vault.update { $0.cursor = account } }
    }

    func delete() async throws {
        try await loadOffMainActor { [vault] in try vault.update { $0.cursor = nil } }
    }
}
