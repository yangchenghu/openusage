import os
import XCTest
@testable import OpenUsage

final class CursorLoginTests: XCTestCase {
    func testPollVerifierIsNeverWrittenToHTTPLogs() {
        let request = CursorLogin.Request(id: "private-request-id", verifier: "a-secret-pkce-verifier-long-enough-to-mask")
        let redacted = LogRedaction.redactURL(request.pollURL.absoluteString)
        XCTAssertFalse(redacted.contains(request.verifier))
        XCTAssertFalse(redacted.contains(request.id))
        XCTAssertTrue(redacted.contains("verifier=[REDACTED]"))
    }

    func testBrowserAndPollShareThePKCERequest() throws {
        let request = CursorLogin.Request(id: "test-id", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let browser = try XCTUnwrap(URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (browser.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(browser.host, "cursor.com")
        XCTAssertEqual(browser.path, "/loginDeepControl")
        XCTAssertEqual(query["challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["uuid"], "test-id")
        XCTAssertEqual(query["redirectTarget"], "cli")
        XCTAssertNil(query["verifier"])
        let poll = try XCTUnwrap(URLComponents(url: request.pollURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(poll.queryItems?.first { $0.name == "verifier" }?.value, request.verifier)
        XCTAssertEqual(poll.queryItems?.first { $0.name == "uuid" }?.value, "test-id")
    }

    func testPendingAndNetworkFailureAreRetriedUntilAuthorizationCompletes() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let token = makeCursorJWT()
        let http = RoutingHTTPClient { _ in
            let attempt = count.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            if attempt < 4 { return HTTPResponse(statusCode: attempt == 2 ? 202 : 404, headers: [:], body: Data()) }
            return tokenResponse(token)
        }
        let result = try await CursorLogin(http: http, sleep: { _ in }).authorize { _ in }
        XCTAssertEqual(result.accessToken, token)
        XCTAssertEqual(result.refreshToken, "browser-refresh")
        XCTAssertEqual(http.requests.count, 4)
    }

    func testMalformedAndRejectedResponsesFailWithoutAcceptingCredentials() async {
        for response in [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"accessToken":"not-a-session","refreshToken":"r"}"#.utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"accessToken":"x"}"#.utf8)),
            HTTPResponse(statusCode: 403, headers: [:], body: Data())
        ] {
            let http = RoutingHTTPClient { _ in response }
            do {
                _ = try await CursorLogin(http: http, sleep: { _ in }).authorize { _ in }
                XCTFail("Invalid authorization was accepted")
            } catch {}
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testDeadlineAndCancellationStopPolling() async {
        let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1000))
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 202, headers: [:], body: Data()) }
        let login = CursorLogin(http: http, now: { time.withLock { $0 } }, sleep: { _ in
            time.withLock { $0 = $0.addingTimeInterval(301) }
        })
        do { _ = try await login.authorize { _ in }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? CursorLoginError)?.errorDescription, CursorLoginError.timedOut.errorDescription) }
        XCTAssertEqual(http.requests.count, 1)

        let cancelled = Task {
            try await CursorLogin(http: http).authorize { _ in throw CancellationError() }
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.requests.count, 1)
    }
}

@MainActor
final class CursorAccountSessionTests: XCTestCase {
    func testLoginProvesNewTokenThenSavesTheProfileAndRefreshes() async throws {
        let token = makeCursorJWT(sub: "auth0|browser-user")
        let vault = MemoryCursorVault()
        let http = loginHTTP(token: token)
        let session = CursorAccountSession(vault: vault, login: CursorLogin(http: http))
        var opened = false
        var refreshed = false
        let task = session.startSignIn(openBrowser: { url in opened = url.host == "cursor.com"; return true }, onComplete: { refreshed = true })
        await task?.value
        XCTAssertTrue(opened)
        XCTAssertTrue(refreshed)
        XCTAssertFalse(session.isSigningIn)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.account?.label, "browser@example.com")
        let saved = try await vault.load()
        XCTAssertEqual(saved?.accessToken, token)
        XCTAssertEqual(saved?.refreshToken, "browser-refresh")
        XCTAssertEqual(http.requests.first { $0.url == CursorUsageClient.usageURL }?.headers["Authorization"], "Bearer \(token)")
        let reloaded = try await CursorAccountSession(vault: vault).loadAuthState()
        XCTAssertEqual(reloaded?.accessToken, token)
    }

    func testFailedNewLoginAndCancellationKeepTheExistingAccount() async throws {
        let previous = CursorAccount(accessToken: makeCursorJWT(sub: "auth0|previous"), refreshToken: "previous-refresh")
        for cancelled in [false, true] {
            let vault = MemoryCursorVault(previous)
            let session = CursorAccountSession(vault: vault, login: CursorLogin(http: loginHTTP(token: makeCursorJWT(), usageStatus: 401)))
            _ = try await session.loadAuthState()
            var completed = false
            let task = session.startSignIn(openBrowser: { _ in
                if cancelled { session.cancelSignIn() }
                return true
            }, onComplete: { completed = true })
            await task?.value
            XCTAssertFalse(completed)
            XCTAssertEqual(session.account, previous)
            let saved = try await vault.load()
            XCTAssertEqual(saved, previous)
            XCTAssertEqual(session.errorMessage == nil, cancelled)
        }
    }

    func testOwnedCredentialsWinOverLocalLoginAndRenewOnlyInTheirOwnVault() async throws {
        let old = makeCursorJWT(sub: "auth0|browser", exp: 1_800_000_100)
        let new = makeCursorJWT(sub: "auth0|browser", exp: 2_000_000_000)
        let vault = MemoryCursorVault(CursorAccount(accessToken: old, refreshToken: "old-refresh"))
        let session = CursorAccountSession(vault: vault)
        let sqlite = KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "auth0|local")])
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.refreshURL {
                XCTAssertEqual(ProviderParse.jsonObject(request.body ?? Data())?["refresh_token"] as? String, "old-refresh")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"access_token\":\"\(new)\"}".utf8))
            }
            if request.url == CursorUsageClient.usageURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(new)")
                return usageResponse()
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeProvider(session: session, http: http, sqlite: sqlite)
        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(sqlite.writtenValues.isEmpty)
        let saved = try await vault.load()
        XCTAssertEqual(saved?.accessToken, new)
        XCTAssertEqual(saved?.refreshToken, new, "Cursor's renewed access JWT is the next refresh token")
    }

    func testRenewedTokenSurvivesFailedPersistenceAndRetriesSaving() async throws {
        let previous = CursorAccount(accessToken: makeCursorJWT(), refreshToken: "refresh")
        let vault = MemoryCursorVault(previous)
        let session = CursorAccountSession(vault: vault)
        let loadedState = try await session.loadAuthState()
        let state = try XCTUnwrap(loadedState)
        await vault.setSaveFailure(true)
        let renewed = makeCursorJWT(sub: "auth0|renewed")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"access_token\":\"\(renewed)\"}".utf8))
        }
        _ = try await session.renew(state, client: CursorUsageClient(http: http))
        XCTAssertEqual(session.account?.accessToken, renewed)
        XCTAssertNotNil(session.persistenceWarning)
        let unsaved = try await vault.load()
        XCTAssertEqual(unsaved, previous)
        await vault.setSaveFailure(false)
        _ = try await session.loadAuthState()
        XCTAssertNil(session.persistenceWarning)
        let saved = try await vault.load()
        XCTAssertEqual(saved?.accessToken, renewed)
    }

    func testKeychainFailureDoesNotSwitchToAnotherLocalAccount() async {
        let vault = MemoryCursorVault()
        await vault.setLoadFailure(true)
        let http = RoutingHTTPClient { _ in XCTFail("A Keychain failure must not trigger requests with another login"); return usageResponse() }
        let provider = makeProvider(session: CursorAccountSession(vault: vault), http: http)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
    }

    func testLogoutRemovesOwnedCredentials() async throws {
        let vault = MemoryCursorVault(CursorAccount(accessToken: makeCursorJWT(), refreshToken: "r"))
        let session = CursorAccountSession(vault: vault)
        _ = try await session.loadAuthState()
        try await session.signOut()
        let state = try await session.loadAuthState()
        let saved = try await vault.load()
        XCTAssertNil(state)
        XCTAssertNil(saved)
    }

    func testRestoredLoginAndLogoutUpdateProviderEnablement() async throws {
        for signedIn in [false, true] {
            let suite = "OpenUsageTests.CursorEnablement.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let enablement = ProviderEnablementStore(defaults: defaults)
            enablement.setEnabled(!signedIn, for: "cursor")
            let account = signedIn ? CursorAccount(accessToken: makeCursorJWT(), refreshToken: "r") : nil
            let session = CursorAccountSession(vault: MemoryCursorVault(account))
            session.onAuthenticationChanged = { enablement.setEnabled($0, for: "cursor") }
            _ = try await session.loadAuthState()
            XCTAssertEqual(enablement.isEnabled("cursor"), signedIn)
            if signedIn {
                try await session.signOut()
                XCTAssertFalse(enablement.isEnabled("cursor"))
                XCTAssertNil(session.account)
            }
            XCTAssertFalse(ProviderEnablementStore(defaults: defaults).isEnabled("cursor"))
        }
    }

    func testOnlySuccessfulLoginEnablesCursor() async throws {
        for status in [200, 401] {
            let suite = "OpenUsageTests.CursorLoginEnablement.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let enablement = ProviderEnablementStore(defaults: defaults)
            let session = CursorAccountSession(vault: MemoryCursorVault(), login: CursorLogin(http: loginHTTP(token: makeCursorJWT(), usageStatus: status)))
            session.onAuthenticationChanged = { enablement.setEnabled($0, for: "cursor") }
            _ = try await session.loadAuthState()
            let task = session.startSignIn(openBrowser: { _ in true }, onComplete: {})
            await task?.value
            XCTAssertEqual(enablement.isEnabled("cursor"), status == 200)
        }
    }

    func testFailedLogoutKeepsTheAccountAndProviderEnabled() async throws {
        let previous = CursorAccount(accessToken: makeCursorJWT(), refreshToken: "r")
        let vault = MemoryCursorVault(previous)
        let session = CursorAccountSession(vault: vault)
        var enabled = false
        session.onAuthenticationChanged = { enabled = $0 }
        _ = try await session.loadAuthState()
        await vault.setDeleteFailure(true)
        do { try await session.signOut(); XCTFail("Expected Keychain failure") }
        catch { XCTAssertEqual((error as? CursorLoginError)?.errorDescription, CursorLoginError.keychain.errorDescription) }
        XCTAssertTrue(enabled)
        XCTAssertEqual(session.account, previous)
    }

    func testLoggedOutCursorIsNotReenabledFromLocalTokensOrResetFallback() async {
        let session = CursorAccountSession(vault: MemoryCursorVault())
        let http = RoutingHTTPClient { _ in XCTFail("Logged-out Cursor must not use another local login"); return usageResponse() }
        let provider = makeProvider(session: session, http: http,
            sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "auth0|local")]))
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let suite = "OpenUsageTests.CursorResetEnablement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let enablement = ProviderEnablementStore(defaults: defaults)
        await FirstRunSeeder.reseed(providers: [provider], enablement: enablement).value
        XCTAssertFalse(enablement.isEnabled("cursor"))
    }

    func testRejectedOwnedLoginDoesNotFallBackToAnotherCursorAppAccount() async {
        let account = CursorAccount(accessToken: makeCursorJWT(sub: "auth0|owned"), refreshToken: "revoked")
        let session = CursorAccountSession(vault: MemoryCursorVault(account))
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.refreshURL {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data(#"{"shouldLogout":true}"#.utf8))
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(account.accessToken)")
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = makeProvider(session: session, http: http,
            sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "auth0|different-local-account")]))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(session.account, account)
    }

    func testFailedSaveOfANewLoginKeepsThePreviousAccount() async throws {
        let previous = CursorAccount(accessToken: makeCursorJWT(sub: "auth0|previous"), refreshToken: "r")
        let vault = MemoryCursorVault(previous)
        await vault.setSaveFailure(true)
        let session = CursorAccountSession(vault: vault, login: CursorLogin(http: loginHTTP(token: makeCursorJWT())))
        _ = try await session.loadAuthState()
        let task = session.startSignIn(openBrowser: { _ in true }, onComplete: { XCTFail("A login that wasn't saved must not complete") })
        await task?.value
        XCTAssertEqual(session.account, previous)
        XCTAssertNotNil(session.errorMessage)
        let saved = try await vault.load()
        XCTAssertEqual(saved, previous)
    }

    func testTemporaryRenewalFailuresDoNotBecomeExpiredSignIns() async throws {
        for status in [400, 403, 429, 503] {
            let previous = CursorAccount(accessToken: makeCursorJWT(), refreshToken: "refresh")
            let session = CursorAccountSession(vault: MemoryCursorVault(previous))
            let loaded = try await session.loadAuthState()
            let state = try XCTUnwrap(loaded)
            let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: status, headers: [:], body: Data()) }
            do {
                _ = try await session.renew(state, client: CursorUsageClient(http: http))
                XCTFail("Expected request failure")
            } catch {
                XCTAssertEqual(error as? CursorUsageError, .requestFailed(status))
            }
            XCTAssertEqual(session.account, previous)
        }
    }

    func testAccountSwitchRemovesThePreviousSnapshotFromMemoryAndDisk() async {
        let suite = "OpenUsageTests.CursorAccountCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = makeProvider(session: CursorAccountSession(vault: MemoryCursorVault()), http: RoutingHTTPClient { _ in usageResponse() })
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.store(ProviderSnapshot.make(provider: provider.provider, plan: "Old Account", lines: [
            .progress(label: "Total usage", used: 80, limit: 100, format: .percent)
        ], refreshedAt: Date()))
        let store = WidgetDataStore(registry: WidgetRegistry.from([provider]), providers: [provider], cache: cache, defaults: defaults)
        XCTAssertNotNil(store.snapshots["cursor"])
        store.providerAccountDidChange("cursor")
        XCTAssertNil(store.localSnapshots["cursor"])
        XCTAssertNil(store.snapshots["cursor"])
        let disk = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").loadSnapshots(providerIDs: ["cursor"])
        XCTAssertNil(disk["cursor"])
    }

    private func makeProvider(session: CursorAccountSession, http: RoutingHTTPClient, sqlite: KeyValueSQLite = KeyValueSQLite()) -> CursorProvider {
        CursorProvider(authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain(), now: { Date(timeIntervalSince1970: 1_800_000_000) }),
            accountSession: session, usageClient: CursorUsageClient(http: http), now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }, spendHistoryBudget: 0)
    }
}

private actor MemoryCursorVault: CursorAccountVault {
    var account: CursorAccount?
    var failLoad = false
    var failSave = false
    var failDelete = false
    init(_ account: CursorAccount? = nil) { self.account = account }
    func load() throws -> CursorAccount? { if failLoad { throw CursorLoginError.keychain }; return account }
    func save(_ account: CursorAccount) throws { if failSave { throw CursorLoginError.keychain }; self.account = account }
    func delete() throws { if failDelete { throw CursorLoginError.keychain }; account = nil }
    func setLoadFailure(_ fail: Bool) { failLoad = fail }
    func setSaveFailure(_ fail: Bool) { failSave = fail }
    func setDeleteFailure(_ fail: Bool) { failDelete = fail }
}

private func tokenResponse(_ token: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"accessToken\":\"\(token)\",\"refreshToken\":\"browser-refresh\"}".utf8))
}

private func usageResponse() -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"planUsage":{"totalPercentUsed":27}}"#.utf8))
}

private func loginHTTP(token: String, usageStatus: Int = 200) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        if request.url.path == CursorLogin.pollURL.path { return tokenResponse(token) }
        if request.url == CursorUsageClient.usageURL {
            return HTTPResponse(statusCode: usageStatus, headers: [:], body: usageResponse().body)
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"email":"browser@example.com"}"#.utf8))
    }
}
