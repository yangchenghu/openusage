import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codex: CodexAccountDiscovery = CodexAccountDiscovery(),
        claudeIdentityKeys: [String: String] = [:],
        signIn: SignInStores = .live
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        var providers: [ProviderRuntime]
        // The OpenUsage sign-in belongs to one card: the default `claude` card, else the first.
        let signInClaudeCardID = claudeCards.first { $0.id == "claude" }?.id ?? claudeCards.first?.id
        if claudeCards.isEmpty {
            providers = [ClaudeProvider(authStore: ClaudeAuthStore(
                signIn: signIn.claude, signInMode: .stored(providerID: "claude", defaults: defaults)
            ))]
        } else {
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage,
                    additionalConfigDirectories: card.additionalLogDirectories
                )
                return ClaudeProvider(
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        displayName: claudeCards.count == 1 ? "Claude" : card.displayName
                    ),
                    authStore: ClaudeAuthStore(
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        swapAccount: card.swapAccount,
                        preferOrganizationScopedDesktop: claudeCards.count > 1
                            && card.organizationID != nil && !card.usesDesktopCredentials,
                        signIn: card.id == signInClaudeCardID ? signIn.claude : nil,
                        signInMode: .stored(providerID: card.id, defaults: defaults)
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        if codex.cards.isEmpty {
            providers.append(CodexProvider(
                authStore: CodexAuthStore(
                    additionalAuthHomes: codex.plainAuthHomes,
                    writableAuthHomes: Set(codex.plainWritableAuthHomes),
                    piCredentialSources: codex.plainPiCredentialSources,
                    signIn: signIn.codex,
                    signInMode: .stored(providerID: "codex", defaults: defaults)
                ),
                logUsageScanner: CodexLogUsageScanner(additionalHomes: codex.plainAuthHomes)
            ))
        } else {
            // The OpenUsage sign-in belongs to one card: the default `codex` card, else the first.
            let signInCodexCardID = codex.cards.first { $0.id == "codex" }?.id ?? codex.cards.first?.id
            providers += codex.cards.map { card in
                CodexProvider(
                    provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
                    authStore: CodexAuthStore(
                        expectedIdentity: card.identity,
                        additionalAuthHomes: card.authHomes,
                        writableAuthHomes: Set(card.writableAuthHomes),
                        piCredentialSources: card.piCredentialSources,
                        signIn: card.id == signInCodexCardID ? signIn.codex : nil,
                        signInMode: .stored(providerID: card.id, defaults: defaults)
                    ),
                    historyScope: .account(card.identity, codex.historyHomes, claimsPiUsage: card.claimsPiUsage)
                )
            }
        }
        providers += [
            CursorProvider(accountSession: CursorAccountSession(), signInMode: .stored(providerID: "cursor", defaults: defaults)),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            CryptoPriceProvider(settings: .load(from: defaults)),
            DevinProvider(),
            GrokProvider(signIn: signIn.grok, signInMode: .stored(providerID: "grok", defaults: defaults)),
            OllamaProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return providers
    }
}
