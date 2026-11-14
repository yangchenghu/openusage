import Foundation

extension CursorProvider {
    func fetchUsageWithRetry(accessToken: String, authState: inout CursorAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(authState: working) else {
                    throw CursorAuthError.tokenExpired
                }
                working.accessToken = refreshed
                return refreshed
            },
            connectionFailed: CursorUsageError.connectionFailed,
            retriedConnectionFailed: CursorUsageError.usageAfterRefreshFailed,
            authExpired: CursorAuthError.tokenExpired
        )
    }

    func refreshAccessToken(authState: CursorAuthState) async throws -> String? {
        if authState.source == .openUsage, let accountSession {
            return try await accountSession.renew(authState, client: usageClient)
        }
        // Cursor's browser/CLI session can use its JWT as the refresh token. Keep an explicitly
        // stored refresh token first, but support local sessions that only carry the access JWT.
        let accessJWT = authState.accessToken.flatMap {
            CursorAuthStore.tokenSubject($0) == nil ? nil : $0
        }
        guard let refreshToken = authState.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? accessJWT else {
            return nil
        }

        let response = try await usageClient.refreshToken(refreshToken)
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = ProviderParse.jsonObject(response.body)
            if body?["shouldLogout"] as? Bool == true {
                throw CursorAuthError.sessionExpired
            }
            throw CursorAuthError.tokenExpired
        }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body)
        else {
            return nil
        }
        if body["shouldLogout"] as? Bool == true {
            throw CursorAuthError.sessionExpired
        }
        guard let accessToken = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        // Fail loudly, but do NOT interpolate the error: the Cursor token is persisted via a SQL
        // statement that embeds the token, and a sqlite3 failure surfaces as stderr that could echo a
        // fragment of that statement (JWTs aren't covered by log redaction). A generic error line keeps
        // it loud without risking a token leak. The refreshed token still works for this session.
        do {
            let source = authState.source
            try await loadOffMainActor { [authStore, accessToken, source] in
                try authStore.saveAccessToken(accessToken, source: source)
            }
        } catch {
            AppLog.error(LogTag.auth("cursor"), "failed to persist rotated access token to the Cursor state DB; using it for this session only")
        }
        return accessToken
    }
}
