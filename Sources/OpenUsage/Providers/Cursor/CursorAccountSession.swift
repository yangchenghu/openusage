import Foundation
import Observation

/// App-owned so opening the browser or closing the menu panel does not cancel authorization.
@MainActor
@Observable
final class CursorAccountSession {
    private(set) var account: CursorAccount?
    private(set) var isSigningIn = false
    private(set) var authorizationURL: URL?
    private(set) var errorMessage: String?
    private(set) var persistenceWarning: String?
    private(set) var revision = 0
    @ObservationIgnored var onAuthenticationChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadTask: Task<CursorAccount?, Error>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var attemptID = UUID()
    @ObservationIgnored private var membershipReadAt: Date?
    @ObservationIgnored private var membership: String?
    @ObservationIgnored private var needsPersistence = false
    let vault: any CursorAccountVault
    let login: CursorLogin

    init(vault: any CursorAccountVault = CursorSignInVault(vault: .shared), login: CursorLogin = CursorLogin()) {
        self.vault = vault
        self.login = login
    }

    func loadAuthState() async throws -> CursorAuthState? {
        if !loaded {
            let expectedRevision = revision
            let task = loadTask ?? Task { try await vault.load() }
            loadTask = task
            defer { loadTask = nil }
            let saved = try await task.value
            if revision == expectedRevision {
                account = saved
                loaded = true
                onAuthenticationChanged?(saved != nil)
            }
        }
        if needsPersistence, let account { await persistRenewal(account) }
        return account?.authState
    }

    @discardableResult
    func startSignIn(
        openBrowser: @escaping @MainActor (URL) -> Bool,
        onComplete: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard !isSigningIn else { return nil }
        let attempt = UUID()
        attemptID = attempt
        revision += 1
        isSigningIn = true
        errorMessage = nil
        loginTask = Task {
            defer {
                if attemptID == attempt { isSigningIn = false; authorizationURL = nil; loginTask = nil }
            }
            do {
                var signedIn = try await login.authorize { url in
                    try await MainActor.run {
                        self.authorizationURL = url
                        guard openBrowser(url) else { throw CursorLoginError.browserUnavailable }
                    }
                }
                let client = CursorUsageClient(http: login.http)
                // A new login must prove itself with its own usage request before replacing the old one.
                let response = try await client.fetchUsage(accessToken: signedIn.accessToken)
                try ProviderAuthRetry.requireSuccess(response, authExpired: CursorAuthError.tokenExpired,
                    requestFailed: { CursorUsageError.requestFailed($0) })
                guard ProviderParse.jsonObject(response.body) != nil else { throw CursorLoginError.invalidResponse }
                if let profile = try? await client.fetchProfile(accessToken: signedIn.accessToken),
                   (200..<300).contains(profile.statusCode), let body = ProviderParse.jsonObject(profile.body) {
                    signedIn.label = (body["email"] as? String)?.nilIfEmpty ?? (body["name"] as? String)?.nilIfEmpty ?? signedIn.label
                } else {
                    AppLog.warn(LogTag.auth("cursor"), "optional profile read failed after sign-in")
                }
                try Task.checkCancellation()
                try await vault.save(signedIn)
                account = signedIn
                loaded = true
                revision += 1
                membershipReadAt = nil
                membership = nil
                persistenceWarning = nil
                needsPersistence = false
                onAuthenticationChanged?(true)
                await onComplete()
            } catch is CancellationError {
                // Cancellation leaves the previously saved login in place.
            } catch {
                if attemptID == attempt {
                    errorMessage = error.localizedDescription
                    AppLog.error(LogTag.auth("cursor"), "browser sign-in failed")
                }
            }
        }
        return loginTask
    }

    func cancelSignIn() {
        loginTask?.cancel()
    }

    func signOut() async throws {
        revision += 1
        try await vault.delete()
        account = nil
        loaded = true
        revision += 1
        membershipReadAt = nil
        membership = nil
        errorMessage = nil
        persistenceWarning = nil
        needsPersistence = false
        onAuthenticationChanged?(false)
    }

    /// Saves a login exported from another Mac as OpenUsage's Cursor login. The caller turns Cursor on.
    func adopt(_ imported: CursorAccount) async throws {
        revision += 1
        try await vault.save(imported)
        account = imported
        loaded = true
        revision += 1
        membershipReadAt = nil
        membership = nil
        errorMessage = nil
        persistenceWarning = nil
        needsPersistence = false
        AppLog.info(LogTag.auth("cursor"), "imported an OpenUsage Cursor login")
    }

    func renew(_ state: CursorAuthState, client: CursorUsageClient) async throws -> String {
        guard let current = account, current.accessToken == state.accessToken else { throw CancellationError() }
        let expectedRevision = revision
        let response = try await client.refreshToken(current.refreshToken)
        let body = ProviderParse.jsonObject(response.body)
        if body?["shouldLogout"] as? Bool == true { throw CursorAuthError.sessionExpired }
        let errorCode = body?["error"] as? String
            ?? (body?["error"] as? [String: Any])?["code"] as? String
            ?? body?["code"] as? String
        if [400, 401, 403].contains(response.statusCode),
           let errorCode, ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(errorCode) {
            throw CursorAuthError.tokenExpired
        }
        guard (200..<300).contains(response.statusCode) else { throw CursorUsageError.requestFailed(response.statusCode) }
        guard let accessToken = (body?["access_token"] as? String)?.nilIfEmpty else { throw CursorLoginError.invalidResponse }
        guard account == current, revision == expectedRevision else { throw CancellationError() }
        var renewed = current
        renewed.accessToken = accessToken
        renewed.refreshToken = (body?["refresh_token"] as? String)?.nilIfEmpty ?? accessToken
        account = renewed
        await persistRenewal(renewed)
        return accessToken
    }

    private func persistRenewal(_ renewed: CursorAccount) async {
        do {
            try await vault.save(renewed)
            persistenceWarning = nil
            needsPersistence = false
        } catch {
            needsPersistence = true
            persistenceWarning = "Cursor sign-in renewed, but couldn't be saved to Keychain. Keep OpenUsage running and try again."
            AppLog.error(LogTag.auth("cursor"), "could not save renewed browser credentials; keeping them in memory")
        }
    }

    func membershipType(client: CursorUsageClient, accessToken: String, now: Date) async -> String? {
        if let membershipReadAt, now.timeIntervalSince(membershipReadAt) < 3600 { return membership }
        membershipReadAt = now
        do {
            guard let response = try await client.fetchUsageSummary(accessToken: accessToken),
                  (200..<300).contains(response.statusCode), let summary = ProviderParse.jsonObject(response.body) else {
                AppLog.warn(LogTag.plugin("cursor"), "browser account membership read failed")
                return membership
            }
            membership = (summary["membershipType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "browser account membership request failed")
        }
        return membership
    }
}
