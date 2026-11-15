import Foundation

extension GrokProvider {
    /// The OpenUsage sign-in is Grok's only source; signed out, it reports that instead of reading
    /// (and rotating) the Grok CLI's login.
    func refreshSignedIn() async -> ProviderSnapshot {
        guard let signIn else { return ProviderSnapshot.error(provider: provider, error: GrokAuthError.notSignedIn) }
        let loaded: SignedInAccount?
        do {
            loaded = try await loadOffMainActor { try signIn.load() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard var account = loaded else {
            return ProviderSnapshot.error(provider: provider, error: GrokAuthError.notSignedIn)
        }
        do {
            if account.needsRenewal(now: now()) {
                account = try await renewSignIn(account, store: signIn)
            }
            var current = account
            let credits = try await ProviderAuthRetry.fetch(
                token: account.accessToken,
                attempt: { try await self.usageClient.fetchCreditsConfig(accessToken: $0) },
                refreshAccessToken: {
                    current = try await self.renewSignIn(current, store: signIn)
                    return current.accessToken
                },
                connectionFailed: GrokUsageError.connectionFailed,
                authExpired: GrokAuthError.signInExpired
            )
            return try await snapshot(creditsResponse: credits, accessToken: current.accessToken)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    func loadSignedInAccount() async -> SignedInAccount? {
        guard let signIn else { return nil }
        return await loadOffMainActor { (try? signIn.load()) ?? nil }
    }

    /// Renews the sign-in. Only a refusal of the refresh token is an expired sign-in; anything else is an
    /// ordinary request failure and the next refresh tries again. A Keychain write failure keeps the new
    /// tokens in the store's memory (see `SignedInAccountKeychainStore`) and is logged, not fatal.
    private func renewSignIn(_ account: SignedInAccount, store: any SignedInAccountStoring) async throws -> SignedInAccount {
        guard let refreshToken = account.refreshToken?.nilIfEmpty else { throw GrokAuthError.signInExpired }
        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(refreshToken, clientID: GrokAuthStore.defaultClientID)
        } catch {
            throw GrokUsageError.connectionFailed
        }
        if OAuthTokenResponse.isRefusedRenewal(response) {
            AppLog.warn(LogTag.auth("grok"), "OpenUsage sign-in renewal refused")
            throw GrokAuthError.signInExpired
        }
        guard (200..<300).contains(response.statusCode) else { throw GrokUsageError.requestFailed(response.statusCode) }
        guard let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: response.body),
              !token.accessToken.isEmpty
        else { throw GrokUsageError.invalidResponse }
        let renewed = account.renewed(with: token, now: now())
        do {
            try await loadOffMainActor { try store.save(renewed) }
        } catch {
            AppLog.error(LogTag.auth("grok"), "couldn't save the renewed sign-in; keeping it in memory: \(error.localizedDescription)")
        }
        AppLog.info(LogTag.auth("grok"), "sign-in renewed")
        return renewed
    }
}
