import Foundation

/// Moving OpenUsage sign-ins between Macs (Settings → Sign-In Transfer). Only OpenUsage's own sign-ins
/// travel; a tool's local login stays on its Mac.
extension AppContainer {
    /// Every saved OpenUsage sign-in, sealed with `password`. Throws `nothingToExport` when there are none.
    func exportSignIns(password: String) async throws -> Data {
        var accounts: [String: SignedInAccount] = [:]
        for session in signInSessions.values {
            let store = session.store
            if let account = try await loadOffMainActor({ try store.load() }) {
                accounts[ProviderAccountID.family(of: session.providerID)] = account
            }
        }
        var cursor: CursorAccount?
        if let session = cursorSignInSession {
            // The session may hold a renewal Keychain refused to save; that's the one to export.
            _ = try await session.loadAuthState()
            cursor = session.account
        }
        let payload = SignInTransferPayload(accounts: accounts, cursor: cursor, exportedAt: Date())
        guard !payload.isEmpty else { throw SignInTransferError.nothingToExport }
        // Key derivation is deliberately slow; keep it off the main actor.
        let data = try await Task.detached { try SignInTransferFile.seal(payload, password: password) }.value
        AppLog.info(.config, "exported OpenUsage sign-ins: \(payload.accounts.keys.sorted() + (cursor == nil ? [] : ["cursor"]))")
        return data
    }

    /// Opens an export and saves each sign-in as its card's OpenUsage sign-in, switching those cards to
    /// OpenUsage Sign-In and turning them on. Returns the imported providers' display names.
    @discardableResult
    func importSignIns(_ data: Data, password: String) async throws -> [String] {
        let payload = try await Task.detached { try SignInTransferFile.open(data, password: password) }.value
        var importedIDs: [String] = []
        for session in signInSessions.values.sorted(by: { $0.providerID < $1.providerID }) {
            guard let account = payload.accounts[ProviderAccountID.family(of: session.providerID)] else { continue }
            try await session.adopt(account)
            importedIDs.append(session.providerID)
        }
        if let account = payload.cursor, let session = cursorSignInSession {
            try await session.adopt(account)
            importedIDs.append("cursor")
        }
        guard !importedIDs.isEmpty else { throw SignInTransferError.nothingToImport }
        for id in importedIDs {
            signInModes.set(.openUsage, for: id)
            dataStore.providerAccountDidChange(id)
            enablement.setEnabled(true, for: id)
        }
        AppLog.info(.config, "imported OpenUsage sign-ins: \(importedIDs)")
        Task {
            for id in importedIDs { await dataStore.refresh(providerID: id, force: true) }
        }
        return importedIDs.map { id in registry.providers.first { $0.id == id }?.displayName ?? id }
    }
}
