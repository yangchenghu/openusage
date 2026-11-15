import Foundation

/// Claude's in-app browser sign-in (OAuth + PKCE, localhost callback or pasted `code#state`), ported
/// from OpenUsage 0.8.0. Uses Claude Code's public OAuth client, so the tokens renew through the same
/// endpoint `ClaudeProvider.refreshAccessToken` already calls; they live in OpenUsage's own Keychain
/// item and never touch Claude Code's login.
struct ClaudeSignIn: ProviderSignIn {
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    /// `/api/oauth/usage` and `/api/oauth/profile` need `user:profile`; spending a reset needs
    /// `user:inference`. Renewal sends the granted string back unchanged.
    static let scopes = "user:profile user:inference"

    var authStore = ClaudeAuthStore()
    var http: any HTTPClient = URLSessionHTTPClient()
    private var usageClient: ClaudeUsageClient { ClaudeUsageClient(httpClient: http) }

    func login(
        prompt: @escaping @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignedInAccount {
        let config = try authStore.oauthConfig()
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server = try await LoopbackCallbackServer.start(state: state)
        let code = try await authorizeInBrowser(
            Self.authorizeURL, clientID: config.clientID, scopes: Self.scopes, state: state, pkce: pkce,
            server: server, extraQuery: [URLQueryItem(name: "code", value: "true")],
            prompt: prompt, pastedCode: pastedCode
        )
        let response = try await LoginHTTP.postJSON(config.refreshURL, fields: [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "state": state,
            "redirect_uri": server.redirectURI,
            "code_verifier": pkce.verifier
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)

        // The new login must prove itself (and name its account) before it replaces anything.
        let profileResponse = try await usageClient.fetchProfile(accessToken: token.accessToken, config: config)
        guard (200..<300).contains(profileResponse.statusCode),
              let profile = try? JSONDecoder().decode(ClaudeSignInProfile.self, from: profileResponse.body)
        else {
            AppLog.error(LogTag.auth("claude"), "profile read failed after the token exchange (HTTP \(profileResponse.statusCode))")
            throw LoginError.failed("Claude didn't return your profile. Try signing in again.")
        }
        var identity = profile.account.uuid.lowercased()
        if let org = profile.organization?.uuid?.nilIfEmpty { identity += "|\(org.lowercased())" }
        return token.account(
            label: profile.account.email ?? profile.email ?? "Claude Account",
            scopes: Self.scopes,
            extras: [SignedInAccount.identityKey: identity]
        )
    }
}

private struct ClaudeSignInProfile: Decodable {
    struct Account: Decodable { let email: String?; let uuid: String }
    struct Organization: Decodable { let uuid: String? }
    let account: Account
    let organization: Organization?
    let email: String?
}
