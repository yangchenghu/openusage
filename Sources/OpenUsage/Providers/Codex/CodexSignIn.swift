import Foundation

/// ChatGPT (Codex) in-app sign-in, ported from OpenUsage 0.8.0: a browser OAuth + PKCE sign-in on the
/// Codex CLI's localhost port 1455, falling back to device authorization when that port is busy (for
/// example while `codex login` is running). Uses the Codex CLI's public client, so the tokens renew
/// through `CodexUsageClient.refreshToken`; they live in OpenUsage's own Keychain item and never touch
/// `~/.codex/auth.json`.
struct CodexSignIn: ProviderSignIn {
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let scopes = "openid profile email offline_access"
    static let callbackPort: UInt16 = 1455

    var http: any HTTPClient = URLSessionHTTPClient()

    func login(
        prompt: @escaping @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignedInAccount {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server: LoopbackCallbackServer
        do {
            server = try await LoopbackCallbackServer.start(state: state, port: Self.callbackPort, path: "/auth/callback")
        } catch {
            AppLog.info(LogTag.auth("codex"), "port \(Self.callbackPort) unavailable; using device sign-in")
            return try await deviceLogin(prompt: prompt)
        }
        let code = try await authorizeInBrowser(
            Self.authorizeURL, clientID: CodexUsageClient.clientID, scopes: Self.scopes, state: state, pkce: pkce,
            server: server,
            extraQuery: [
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "codex_cli_rs")
            ],
            prompt: prompt, pastedCode: pastedCode
        )
        return try await exchange(code: code, verifier: pkce.verifier, redirectURI: server.redirectURI)
    }

    private func deviceLogin(prompt: @escaping @Sendable (LoginPrompt) async -> Void) async throws -> SignedInAccount {
        let start = try await LoginHTTP.postJSON(
            URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!,
            fields: ["client_id": CodexUsageClient.clientID], using: http
        )
        let device = try LoginHTTP.decode(CodexDeviceStart.self, from: start)
        await prompt(.deviceCode(userCode: device.userCode, verificationURL: URL(string: "https://auth.openai.com/codex/device")!))
        let interval = ProviderParse.number(ProviderParse.jsonObject(start.body)?["interval"]) ?? 5
        let deviceToken: CodexDeviceToken = try await DeviceCodePoller.poll(interval: interval, expiresIn: 900) { [http] in
            let response = try await LoginHTTP.postJSON(
                URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!,
                fields: ["device_auth_id": device.deviceAuthID, "user_code": device.userCode], using: http
            )
            if (200..<300).contains(response.statusCode) {
                return .complete(try LoginHTTP.decode(CodexDeviceToken.self, from: response))
            }
            if response.statusCode == 403 || response.statusCode == 404 { return .pending }
            let error = OAuthTokenResponse.errorCode(response.body) ?? ""
            if error == "deviceauth_authorization_pending" { return .pending }
            if error == "slow_down" { return .slowDown }
            return .failed(error == "expired_token" ? "ChatGPT device sign-in expired." : "ChatGPT device sign-in failed.")
        }
        return try await exchange(
            code: deviceToken.authorizationCode,
            verifier: deviceToken.codeVerifier,
            redirectURI: "https://auth.openai.com/deviceauth/callback"
        )
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> SignedInAccount {
        let response = try await LoginHTTP.postForm(CodexUsageClient.refreshURL, fields: [
            "grant_type": "authorization_code",
            "client_id": CodexUsageClient.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)
        let auth = ProviderParse.jwtPayload(token.accessToken)?["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = (auth?["chatgpt_account_id"] as? String)?.nilIfEmpty else {
            AppLog.error(LogTag.auth("codex"), "sign-in token carries no ChatGPT account")
            throw LoginError.failed("ChatGPT didn't return an account for this sign-in. Try again.")
        }
        let email = token.idToken.flatMap(ProviderParse.jwtPayload)?["email"] as? String
        var extras = [SignedInAccount.chatGPTAccountIDKey: accountID]
        extras[SignedInAccount.idTokenKey] = token.idToken
        extras[SignedInAccount.identityKey] = email.map { "\(accountID)/\($0)" }
        return token.account(label: email ?? "ChatGPT Account", scopes: Self.scopes, extras: extras)
    }
}

private struct CodexDeviceStart: Decodable {
    let deviceAuthID: String
    let userCode: String
    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct CodexDeviceToken: Decodable {
    let authorizationCode: String
    let codeVerifier: String
    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
    }
}
