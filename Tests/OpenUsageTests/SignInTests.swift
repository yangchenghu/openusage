import os
import XCTest
@testable import OpenUsage

/// In-memory stand-in for `SignInVaultAccountStore`.
final class InMemorySignInStore: SignedInAccountStoring, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<SignedInAccount?>
    init(_ account: SignedInAccount? = nil) { state = OSAllocatedUnfairLock(initialState: account) }
    var account: SignedInAccount? { state.withLock { $0 } }
    func load() throws -> SignedInAccount? { state.withLock { $0 } }
    func save(_ account: SignedInAccount) throws { state.withLock { $0 = account } }
    func delete() throws { state.withLock { $0 = nil } }
}

/// Counts every read so a test can prove the CLI's Keychain was never touched.
private final class CountingKeychain: KeychainAccessing, @unchecked Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    var readCount: Int { reads.withLock { $0 } }
    func readGenericPassword(service: String) throws -> String? { reads.withLock { $0 += 1 }; return nil }
    func writeGenericPassword(service: String, value: String) throws { XCTFail("must not write the CLI Keychain") }
    func readGenericPassword(service: String, account: String) throws -> String? { reads.withLock { $0 += 1 }; return nil }
    func writeGenericPassword(service: String, account: String, value: String) throws { XCTFail("must not write the CLI Keychain") }
    func genericPasswordExists(service: String) -> Bool? { reads.withLock { $0 += 1 }; return false }
}

private struct FailingStore: SignedInAccountStoring {
    func load() throws -> SignedInAccount? { throw SignInStoreError.keychain(-25300) }
    func save(_ account: SignedInAccount) throws {}
    func delete() throws {}
}

final class SignInSupportTests: XCTestCase {
    func testPastedCodeFormats() throws {
        XCTAssertEqual(try authorizationCode(from: .pasted(" abc#state-1 "), expectedState: "state-1"), "abc")
        XCTAssertEqual(try authorizationCode(
            from: .pasted("http://localhost:1455/auth/callback?code=xyz&state=state-1"), expectedState: "state-1"), "xyz")
        XCTAssertEqual(try authorizationCode(from: .pasted("bare-code"), expectedState: "state-1"), "bare-code")
        XCTAssertThrowsError(try authorizationCode(from: .pasted("abc#other"), expectedState: "state-1")) {
            XCTAssertEqual($0 as? LoginError, .invalidState)
        }
        XCTAssertThrowsError(try authorizationCode(from: .pasted("   "), expectedState: "s"))
    }

    func testRenewalKeepsRefreshTokenWhenNotRotatedAndDetectsRefusal() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = SignedInAccount(label: "a", accessToken: "old", refreshToken: "rt", expiresAt: now, scopes: "s")
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        let renewed = account.renewed(with: response, now: now)
        XCTAssertEqual(renewed.accessToken, "new")
        XCTAssertEqual(renewed.refreshToken, "rt")
        XCTAssertEqual(renewed.expiresAt, now.addingTimeInterval(3600))
        XCTAssertTrue(account.needsRenewal(now: now))
        XCTAssertFalse(renewed.needsRenewal(now: now))

        let refused = HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        let outage = HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>".utf8))
        XCTAssertTrue(OAuthTokenResponse.isRefusedRenewal(refused))
        XCTAssertFalse(OAuthTokenResponse.isRefusedRenewal(outage))
    }
}

@MainActor
final class SignInSessionTests: XCTestCase {
    private struct StubSignIn: ProviderSignIn {
        let result: Result<SignedInAccount, LoginError>
        func login(prompt: @escaping @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> SignedInAccount {
            await prompt(.deviceCode(userCode: "ABCD-1234", verificationURL: URL(string: "https://example.com/device")!))
            return try result.get()
        }
    }

    func testSignInSavesNotifiesAndSignOutClears() async {
        let store = InMemorySignInStore()
        let account = SignedInAccount(label: "me@example.com", accessToken: "t")
        let session = SignInSession(providerID: "grok", store: store,
                                    signIn: StubSignIn(result: .success(account)))
        var changes: [Bool] = []
        var opened: [URL] = []
        session.onAccountChanged = { changes.append($0) }
        await session.load()
        session.startSignIn(openURL: { opened.append($0) })
        while session.isSigningIn { await Task.yield() }

        XCTAssertEqual(store.account, account)
        XCTAssertEqual(session.account?.label, "me@example.com")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/device"])
        XCTAssertNil(session.prompt)

        await session.signOut()
        XCTAssertNil(store.account)
        XCTAssertEqual(changes, [true, false])
    }

    func testFailedSignInKeepsPreviousAccountAndShowsError() async {
        let previous = SignedInAccount(label: "old", accessToken: "t")
        let store = InMemorySignInStore(previous)
        let session = SignInSession(providerID: "grok", store: store,
                                    signIn: StubSignIn(result: .failure(.failed("xAI device sign-in expired."))))
        await session.load()
        session.startSignIn(openURL: { _ in })
        while session.isSigningIn { await Task.yield() }
        XCTAssertEqual(store.account, previous)
        XCTAssertEqual(session.errorMessage, "xAI device sign-in expired.")
    }
}

@MainActor
final class ClaudeSignInIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSignInTakesOverWithoutAClaudeCodeLoginAndRenewsIntoOurStore() async throws {
        let keychain = CountingKeychain()
        let store = InMemorySignInStore(SignedInAccount(
            label: "me@example.com", accessToken: "expiring", refreshToken: "rt-1",
            expiresAt: now.addingTimeInterval(60), scopes: ClaudeSignIn.scopes
        ))
        let refreshScope = OSAllocatedUnfairLock<String?>(initialState: nil)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/v1/oauth/token":
                let scope = (try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])?["scope"] as? String
                refreshScope.withLock { $0 = scope }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"fresh","refresh_token":"rt-2","expires_in":28800}"#.utf8))
            case "/api/oauth/usage":
                XCTAssertEqual(request.headers["Authorization"], "Bearer fresh")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(store: store, keychain: keychain, http: http)

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains(where: \.isError), "\(snapshot.lines)")
        XCTAssertTrue(provider.authStore.signInFallback.isActive)
        XCTAssertEqual(refreshScope.withLock { $0 }, ClaudeSignIn.scopes)
        XCTAssertEqual(store.account?.accessToken, "fresh")
        XCTAssertEqual(store.account?.refreshToken, "rt-2")
    }

    func testRefusedRenewalAsksToSignInAgain() async {
        let store = InMemorySignInStore(SignedInAccount(
            label: "me", accessToken: "expired", refreshToken: "rt", expiresAt: now.addingTimeInterval(-60)))
        let http = RoutingHTTPClient { request in
            request.url.path == "/v1/oauth/token"
                ? HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
                : HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let snapshot = await makeProvider(store: store, keychain: CountingKeychain(), http: http).refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(ProviderSnapshotErrorText.message(snapshot), ClaudeAuthError.signInExpired.localizedDescription)
    }

    func testUnreadableSignInKeepsTheMissingLocalLoginError() async {
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: CountingKeychain(),
                                       signIn: FailingStore(), now: { [now] in now }),
            usageClient: ClaudeUsageClient(httpClient: RoutingHTTPClient { _ in
                XCTFail("no request expected"); return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { [now] in now }, pricing: { TestPricing.bundled }
        )
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.allSatisfy(\.isError))
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertFalse(provider.authStore.signInFallback.isActive)
    }

    private func makeProvider(
        store: InMemorySignInStore,
        keychain: CountingKeychain,
        http: RoutingHTTPClient,
        files: [String: String] = [:]
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles(files), keychain: keychain, signIn: store, now: { [now] in now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { [now] in now },
            pricing: { TestPricing.bundled }
        )
    }
}

/// The error text of a failed snapshot (its error badge).
enum ProviderSnapshotErrorText {
    static func message(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first(where: \.isError) else { return nil }
        return text
    }
}

@MainActor
final class GrokSignInIntegrationTests: XCTestCase {
    func testSignInTakesOverWithoutAGrokCLILoginAndNeverWritesTheCLIFile() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InMemorySignInStore(SignedInAccount(
            label: "me@x.ai", accessToken: "stale", refreshToken: "rt", expiresAt: now.addingTimeInterval(3600)))
        let http = RoutingHTTPClient { request in
            if request.url.path == "/oauth2/token" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"fresh","refresh_token":"rt-2","expires_in":3600}"#.utf8))
            }
            if request.headers["Authorization"] == "Bearer stale" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let files = FakeFiles()
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(
                environment: FakeEnvironment(),
                homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-grok-home") },
                incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.Entry>()
            ),
            now: { now },
            pricing: { TestPricing.bundled },
            signIn: store
        )

        _ = await provider.refresh()

        XCTAssertEqual(store.account?.accessToken, "fresh")
        XCTAssertEqual(store.account?.refreshToken, "rt-2")
        XCTAssertTrue(files.files.isEmpty, "the Grok CLI's auth.json must never be written")
        XCTAssertTrue(http.requests.contains { $0.headers["Authorization"] == "Bearer fresh" })
    }
}

@MainActor
final class CodexSignInIntegrationTests: XCTestCase {
    func testSignInTakesOverWithoutACodexLogin() async {
        let keychain = CountingKeychain()
        let store = InMemorySignInStore(SignedInAccount(
            label: "me@example.com", accessToken: "signed-in-token", refreshToken: "rt",
            extras: [SignedInAccount.chatGPTAccountIDKey: "acct-1"]))
        let http = RoutingHTTPClient { request in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":17,"limit_window_seconds":18000}}}"#.utf8))
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, signIn: store),
            usageClient: CodexUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains(where: \.isError), "\(snapshot.lines)")
        XCTAssertTrue(provider.authStore.signInFallback.isActive)
        let usage = http.requests.first { $0.url.path.contains("usage") }
        XCTAssertEqual(usage?.headers["Authorization"], "Bearer signed-in-token")
        XCTAssertEqual(usage?.headers["ChatGPT-Account-Id"], "acct-1")
    }
}

/// Claude, Codex, and Grok read the tool's own login first; a saved sign-in never shadows a working one.
@MainActor
final class LocalLoginFirstTests: XCTestCase {
    private let cliCredentials = ["/tmp/claude/.credentials.json":
        #"{"claudeAiOauth":{"accessToken":"cli-token","expiresAt":4102444800000,"scopes":["user:profile"]}}"#]

    func testClaudeCodeLoginWinsOverTheSavedSignIn() async {
        let store = InMemorySignInStore(SignedInAccount(label: "me", accessToken: "signed-in-token"))
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer cli-token")
            return request.url.path == "/api/oauth/usage"
                ? HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8))
                : HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                                       files: FakeFiles(cliCredentials), keychain: CountingKeychain(), signIn: store),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled }
        )
        XCTAssertFalse(provider.requiresOpenUsageSignIn)

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains(where: \.isError), "\(snapshot.lines)")
        XCTAssertFalse(provider.authStore.signInFallback.isActive)
        XCTAssertEqual(store.account?.accessToken, "signed-in-token")
    }

    func testWithoutAnyLoginCodexAsksForTheCLILoginAndGrokStillDetectsItsCLI() async {
        let codex = CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: CountingKeychain(),
                                      signIn: InMemorySignInStore()),
            usageClient: CodexUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("no request without a login"); return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )
        let codexSnapshot = await codex.refresh()
        XCTAssertEqual(ProviderSnapshotErrorText.message(codexSnapshot), CodexAuthError.notLoggedIn.localizedDescription)

        let grokFiles = FakeFiles(["~/.grok/auth.json": #"{"cli":{"key":"grok-cli-token"}}"#])
        let grok = GrokProvider(authStore: GrokAuthStore(files: grokFiles), signIn: InMemorySignInStore())
        XCTAssertFalse(grok.requiresOpenUsageSignIn)
        let grokDetected = await grok.hasLocalCredentials()
        XCTAssertTrue(grokDetected, "the Grok CLI's login counts as detected")
    }

    func testResetAllDetectsLocalLoginsOnSignInCards() async throws {
        let suite = "LocalLoginFirst.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let enablement = ProviderEnablementStore(defaults: defaults)
        let claude = ClaudeProvider(authStore: ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: FakeFiles(cliCredentials),
            keychain: CountingKeychain(), signIn: InMemorySignInStore()))
        let codex = CodexProvider(authStore: CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: CountingKeychain(), signIn: InMemorySignInStore()))

        await FirstRunSeeder.reseed(providers: [claude, codex], enablement: enablement).value

        XCTAssertTrue(enablement.isEnabled("claude"))
        XCTAssertFalse(enablement.isEnabled("codex"))
    }
}
