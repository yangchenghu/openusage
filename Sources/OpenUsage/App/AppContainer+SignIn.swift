import Foundation

/// Login methods for the login-gated cards (Claude, Codex, Cursor, Grok). With **Local Login** a card
/// reads the tool already logged in on this Mac and keeps its normal on/off toggle; with **OpenUsage
/// Sign-In** the in-app sign-in is its only source and login/logout replaces the toggle.
extension AppContainer {
    /// One session per provider card that holds a sign-in store. While the card uses its OpenUsage
    /// sign-in, signing in turns it on and refetches with the new account and signing out turns it off.
    /// The previous account's cached usage is dropped on every change.
    static func makeSignInSessions(
        providers: [ProviderRuntime],
        dataStore: WidgetDataStore,
        enablement: ProviderEnablementStore,
        modes: SignInModeStore
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
            session.onAccountChanged = { [weak dataStore, weak enablement, weak modes] signedIn in
                guard modes?.mode(for: id) == .openUsage else { return }
                dataStore?.providerAccountDidChange(id)
                enablement?.setEnabled(signedIn, for: id)
                if signedIn { await dataStore?.refresh(providerID: id, force: true) }
            }
        }
        AppLog.info(.config, "login-gated cards: \(sessions.map(\.providerID).sorted())")
        return Dictionary(uniqueKeysWithValues: sessions.map { ($0.providerID, $0) })
    }

    /// OpenUsage's own Cursor login, whichever login method Cursor uses.
    var cursorSignInSession: CursorAccountSession? {
        (providers.first { $0.provider.id == "cursor" } as? CursorProvider)?.signInSession
    }

    /// Whether the card offers a choice of login method.
    func supportsLoginMethod(_ providerID: String) -> Bool {
        signInSessions[providerID] != nil || (providerID == "cursor" && cursorSignInSession != nil)
    }

    /// Whether the card currently uses its OpenUsage sign-in (so login/logout replaces its toggle).
    func usesOpenUsageSignIn(_ providerID: String) -> Bool {
        supportsLoginMethod(providerID) && signInModes.mode(for: providerID) == .openUsage
    }

    /// Switches a card's login method, drops the other source's cached usage, and turns the card on only
    /// when the new method has a login to use.
    func setLoginMethod(_ mode: SignInMode, for providerID: String) {
        guard supportsLoginMethod(providerID), signInModes.mode(for: providerID) != mode else { return }
        signInModes.set(mode, for: providerID)
        dataStore.providerAccountDidChange(providerID)
        AppLog.info(.config, "login method for \(providerID): \(mode.rawValue)")
        Task {
            let enabled = await hasLogin(providerID, mode: mode)
            enablement.setEnabled(enabled, for: providerID)
            if enabled { await dataStore.refresh(providerID: providerID, force: true) }
        }
    }

    /// Launch: loads every saved OpenUsage sign-in and sets each card's enablement from its login method.
    /// A card that never picked a method (the first launch with login methods) keeps its OpenUsage
    /// sign-in when one is saved, and otherwise switches to local login, on when that login exists.
    func restoreLoginMethods() async {
        for session in signInSessions.values {
            await session.load()
            if session.errorMessage != nil {
                AppLog.error(LogTag.auth(session.providerID), "could not restore OpenUsage sign-in")
            }
            await restoreLoginMethod(session.providerID, isSignedIn: session.isSignedIn)
        }
        if let cursor = cursorSignInSession {
            cursor.onAuthenticationChanged = { [weak self] signedIn in
                guard let self, signInModes.mode(for: "cursor") == .openUsage else { return }
                enablement.setEnabled(signedIn, for: "cursor")
            }
            var signedIn = false
            do {
                signedIn = try await cursor.loadAuthState() != nil
            } catch {
                AppLog.error(LogTag.auth("cursor"), "could not restore Cursor sign-in")
            }
            await restoreLoginMethod("cursor", isSignedIn: signedIn)
        }
    }

    private func restoreLoginMethod(_ providerID: String, isSignedIn: Bool) async {
        if !signInModes.hasStoredMode(for: providerID) {
            let mode: SignInMode = isSignedIn ? .openUsage : .local
            signInModes.set(mode, for: providerID)
            AppLog.info(.config, "login method for \(providerID) defaulted to \(mode.rawValue)")
            if mode == .local {
                enablement.setEnabled(await hasLogin(providerID, mode: .local), for: providerID)
                return
            }
        }
        // Local login keeps the user's own toggle; an unreadable sign-in keeps the card off and the row
        // shows the error.
        if signInModes.mode(for: providerID) == .openUsage {
            enablement.setEnabled(isSignedIn, for: providerID)
        }
    }

    private func hasLogin(_ providerID: String, mode: SignInMode) async -> Bool {
        switch mode {
        case .openUsage:
            if let session = signInSessions[providerID] {
                await session.load()
                return session.isSignedIn
            }
            guard providerID == "cursor", let cursor = cursorSignInSession else { return false }
            return ((try? await cursor.loadAuthState()) ?? nil) != nil
        case .local:
            // Read after the mode is stored, so detection takes the local path.
            return await providers.first { $0.provider.id == providerID }?.hasLocalCredentials() ?? false
        }
    }
}
