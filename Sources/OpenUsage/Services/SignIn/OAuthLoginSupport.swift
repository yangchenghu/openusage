import Foundation

/// What a sign-in asks the user to do while it waits.
enum LoginPrompt: Equatable, Sendable {
    /// Approve in the browser. With `acceptsPastedCode`, the provider's page can also show a code to
    /// paste back when the localhost redirect can't reach the app.
    case browser(URL, acceptsPastedCode: Bool)
    /// Enter `userCode` on `verificationURL` (device authorization).
    case deviceCode(userCode: String, verificationURL: URL)
}

/// One provider's in-app sign-in. Returns an account only after the provider proved the new tokens
/// work (a profile or claims read), so a half-finished sign-in never replaces a working one.
protocol ProviderSignIn: Sendable {
    func login(
        prompt: @escaping @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignedInAccount
}

enum LoginHTTP {
    static func postForm(
        _ url: URL,
        fields: [String: String],
        using client: any HTTPClient,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var requestHeaders = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json"
        ]
        requestHeaders.merge(headers) { _, new in new }
        let body = fields
            .map { "\($0.key)=\($0.value.urlFormEncoded)" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        return try await client.send(HTTPRequest(method: "POST", url: url, headers: requestHeaders, body: body, timeout: 20))
    }

    static func postJSON(_ url: URL, fields: [String: String], using client: any HTTPClient) async throws -> HTTPResponse {
        try await client.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: fields),
            timeout: 20
        ))
    }

    static func get(
        _ url: URL,
        bearerToken: String? = nil,
        using client: any HTTPClient,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var requestHeaders = headers
        if let bearerToken { requestHeaders["Authorization"] = "Bearer \(bearerToken)" }
        return try await client.send(HTTPRequest(method: "GET", url: url, headers: requestHeaders, timeout: 20))
    }

    static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            throw LoginError.requestFailed(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw LoginError.invalidResponse
        }
    }
}

struct OAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let idToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
        case scope
    }

    func account(label: String, scopes: String?, extras: [String: String], now: Date = Date()) -> SignedInAccount {
        SignedInAccount(
            label: label,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) } ?? ProviderParse.jwtExpiry(accessToken),
            scopes: scope ?? scopes,
            extras: extras
        )
    }

    /// RFC 6749 sends `error` as a string; OpenAI also sends `error.code` or a top-level `code`.
    static func errorCode(_ body: Data) -> String? {
        let json = ProviderParse.jsonObject(body)
        let error = json?["error"]
        return error as? String ?? (error as? [String: Any])?["code"] as? String ?? json?["code"] as? String
    }

    /// Only a refusal of the refresh token itself means the sign-in expired; an outage, a rate limit, or
    /// a malformed answer is an ordinary request failure and the next refresh simply renews again.
    static func isRefusedRenewal(_ response: HTTPResponse) -> Bool {
        guard [400, 401, 403].contains(response.statusCode), let code = errorCode(response.body) else { return false }
        return ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code)
    }
}

enum LoginError: LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidResponse
    case requestFailed(Int)
    case invalidState
    case invalidCode
    case listenerFailed(String)
    case invalidCallback
    case authorizationFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .invalidResponse: "The sign-in service returned an invalid response."
        case .requestFailed(let status): "Sign-in failed with HTTP \(status)."
        case .invalidState: "The pasted code doesn't belong to this sign-in. Start again."
        case .invalidCode: "The pasted code was empty or invalid."
        case .listenerFailed(let detail): "Could not start the sign-in callback: \(detail)"
        case .invalidCallback: "The sign-in callback request was invalid."
        case .authorizationFailed(let error): "Authorization failed: \(error)"
        case .failed(let message): message
        }
    }
}

enum AuthorizationInput: Sendable {
    case callback(String)
    case pasted(String)
}

/// Opens the provider's authorize page and waits for either the localhost redirect or a code the user
/// pastes, whichever comes first.
func authorizeInBrowser(
    _ authorizeURL: URL,
    clientID: String,
    scopes: String,
    state: String,
    pkce: PKCEPair,
    server: LoopbackCallbackServer,
    extraQuery: [URLQueryItem] = [],
    prompt: @Sendable (LoginPrompt) async -> Void,
    pastedCode: AsyncStream<String>
) async throws -> String {
    defer { server.cancel() }
    guard var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false) else {
        throw LoginError.invalidResponse
    }
    components.queryItems = [
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: server.redirectURI),
        URLQueryItem(name: "scope", value: scopes),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state)
    ] + extraQuery
    guard let url = components.url else { throw LoginError.invalidResponse }
    await prompt(.browser(url, acceptsPastedCode: true))
    let input = try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: AuthorizationInput.self) { tasks in
            tasks.addTask { .callback(try await server.waitForCode()) }
            tasks.addTask {
                var iterator = pastedCode.makeAsyncIterator()
                guard let value = await iterator.next() else { throw LoginError.cancelled }
                return .pasted(value)
            }
            guard let result = try await tasks.next() else { throw LoginError.cancelled }
            server.cancel()
            tasks.cancelAll()
            return result
        }
    } onCancel: {
        server.cancel()
    }
    return try authorizationCode(from: input, expectedState: state)
}

/// Reads a code from the redirect, or from what the user pasted: a whole callback URL, a `code#state`
/// pair (Claude's manual page), or a bare code.
func authorizationCode(from input: AuthorizationInput, expectedState: String) throws -> String {
    switch input {
    case .callback(let code):
        return code
    case .pasted(let value):
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: (code: String?, state: String?)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parsed = (
                components.queryItems?.first(where: { $0.name == "code" })?.value,
                components.queryItems?.first(where: { $0.name == "state" })?.value
            )
        } else if trimmed.contains("#") {
            let values = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
            parsed = (values.first, values.count > 1 ? values[1] : nil)
        } else {
            parsed = (trimmed, nil)
        }
        guard let code = parsed.code, !code.isEmpty else { throw LoginError.invalidCode }
        // A bare code carries no state to check; a code that does carry one must match this sign-in.
        if let state = parsed.state, state != expectedState { throw LoginError.invalidState }
        return code
    }
}

/// RFC 8628 device authorization: shows the user code, then polls the token endpoint.
func deviceAuthorization(
    provider: String,
    startURL: URL,
    tokenURL: URL,
    clientID: String,
    scopes: String?,
    http: any HTTPClient,
    prompt: @Sendable (LoginPrompt) async -> Void
) async throws -> OAuthTokenResponse {
    var fields = ["client_id": clientID]
    fields["scope"] = scopes
    let start = try await LoginHTTP.postForm(startURL, fields: fields, using: http)
    let device = try LoginHTTP.decode(DeviceCode.self, from: start)
    let candidates = [device.verificationURIComplete, device.verificationURI]
        .map { $0.flatMap { URL(string: $0, relativeTo: startURL)?.absoluteURL } }
    guard let verificationURL = candidates.compactMap({ $0 })
        .first(where: { $0.scheme == "https" && $0.host?.isEmpty == false })
    else { throw LoginError.invalidResponse }
    await prompt(.deviceCode(userCode: device.userCode, verificationURL: verificationURL))
    return try await DeviceCodePoller.poll(interval: device.interval ?? 5, expiresIn: TimeInterval(device.expiresIn)) {
        let response = try await LoginHTTP.postForm(tokenURL, fields: [
            "client_id": clientID,
            "device_code": device.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ], using: http)
        if (200..<300).contains(response.statusCode),
           let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: response.body) {
            return .complete(token)
        }
        return switch OAuthTokenResponse.errorCode(response.body) {
        case "authorization_pending": .pending
        case "slow_down": .slowDown
        case "expired_token": .failed("\(provider) device sign-in expired.")
        case "access_denied": .failed("\(provider) sign-in was denied.")
        default: .failed("\(provider) device sign-in failed.")
        }
    }
}

private struct DeviceCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String?
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}
