import Foundation

/// xAI (Grok) in-app device sign-in, ported from OpenUsage 0.8.0. Uses the Grok CLI's public client,
/// so the tokens renew through `GrokUsageClient.refreshToken`; they live in OpenUsage's own Keychain
/// item and are never written to `~/.grok/auth.json` (whose rotating refresh token the CLI owns).
struct GrokSignIn: ProviderSignIn {
    static let deviceURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    static let scopes = "openid email offline_access grok-cli:access"

    var http: any HTTPClient = URLSessionHTTPClient()

    func login(
        prompt: @escaping @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignedInAccount {
        let token = try await deviceAuthorization(
            provider: "xAI",
            startURL: Self.deviceURL,
            tokenURL: GrokUsageClient.refreshURL,
            clientID: GrokAuthStore.defaultClientID,
            scopes: Self.scopes,
            http: http,
            prompt: prompt
        )
        let claims = ProviderParse.jwtPayload(token.idToken ?? token.accessToken)
        let email = claims?["email"] as? String
        let subject = claims?["sub"] as? String
        var extras: [String: String] = [:]
        extras[SignedInAccount.identityKey] = subject ?? email
        extras[SignedInAccount.idTokenKey] = token.idToken
        return token.account(label: email ?? "Grok Account", scopes: Self.scopes, extras: extras)
    }
}
