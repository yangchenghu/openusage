import Foundation

/// OpenUsage's own sign-ins. Claude, Codex, and Grok read the tool already logged in on this Mac first
/// and fall back to their OpenUsage sign-in only when that has no working login, so they keep their
/// normal on/off toggle. Cursor uses only its OpenUsage login, and login/logout replaces its toggle.
extension AppContainer {
    /// One session per provider card that holds a sign-in store. Signing in turns the card on and
    /// refetches; signing out refetches, so the card goes back to the local login when there is one.
    /// The previous account's cached usage is dropped on every change.
    static func makeSignInSessions(
        providers: [ProviderRuntime],
        dataStore: WidgetDataStore,
        enablement: ProviderEnablementStore
    ) -> [String: SignInSession] {
        var sessions: [SignInSession] = []
        if let claude = providers.compactMap({ $0 as? ClaudeProvider }).first(where: { $0.authStore.signInStore != nil }),
           let store = claude.authStore.signInStore {
            sessions.append(SignInSession(providerID: claude.provider.id, store: store, signIn: ClaudeSignIn()))
        }
        if let codex = providers.compactMap({ $0 as? CodexProvider }).first(where: { $0.authStore.signInStore != nil }),
           let store = codex.authStore.signInStore {
            sessions.append(SignInSession(providerID: codex.provider.id, store: store, signIn: CodexSignIn()))
        }
        if let grok = providers.compactMap({ $0 as? GrokProvider }).first, let store = grok.signInStore {
            sessions.append(SignInSession(providerID: grok.provider.id, store: store, signIn: GrokSignIn()))
        }
        for session in sessions {
            let id = session.providerID
            session.onAccountChanged = { [weak dataStore, weak enablement] signedIn in
                dataStore?.providerAccountDidChange(id)
                if signedIn { enablement?.setEnabled(true, for: id) }
                await dataStore?.refresh(providerID: id, force: true)
            }
        }
        AppLog.info(.config, "cards with an OpenUsage sign-in: \(sessions.map(\.providerID).sorted())")
        return Dictionary(uniqueKeysWithValues: sessions.map { ($0.providerID, $0) })
    }

    /// OpenUsage's own Cursor login.
    var cursorSignInSession: CursorAccountSession? {
        (providers.first { $0.provider.id == "cursor" } as? CursorProvider)?.accountSession
    }

    /// Whether the card is turned on only by its OpenUsage login (so login/logout replaces its toggle).
    func usesOpenUsageSignIn(_ providerID: String) -> Bool {
        providerID == "cursor" && cursorSignInSession != nil
    }

    /// Launch: loads every saved OpenUsage sign-in (one Keychain read, see `SignInVault`) for the
    /// Customize rows, and turns Cursor on or off by whether its login exists.
    func restoreSignIns() async {
        for session in signInSessions.values {
            await session.load()
            if session.errorMessage != nil {
                AppLog.error(LogTag.auth(session.providerID), "could not restore OpenUsage sign-in")
            }
        }
        guard let cursor = cursorSignInSession else { return }
        cursor.onAuthenticationChanged = { [weak self] signedIn in
            self?.enablement.setEnabled(signedIn, for: "cursor")
        }
        do {
            let signedIn = try await cursor.loadAuthState() != nil
            enablement.setEnabled(signedIn, for: "cursor")
        } catch {
            AppLog.error(LogTag.auth("cursor"), "could not restore Cursor sign-in")
            enablement.setEnabled(false, for: "cursor")
        }
    }
}
