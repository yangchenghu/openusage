import XCTest
@testable import OpenUsage

final class SignInTransferFileTests: XCTestCase {
    private let payload = SignInTransferPayload(
        accounts: ["claude": SignedInAccount(label: "me@example.com", accessToken: "at", refreshToken: "rt", scopes: "user:profile")],
        cursor: CursorAccount(accessToken: "cursor-at", refreshToken: "cursor-rt", label: "me@cursor"),
        exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    func testRoundTripKeepsTokensOutOfPlainText() throws {
        let data = try SignInTransferFile.seal(payload, password: "correct horse", rounds: 1_000)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("cursor-rt"))
        XCTAssertFalse(text.contains("me@example.com"))
        XCTAssertEqual(try SignInTransferFile.open(data, password: "correct horse"), payload)
    }

    func testWrongPasswordShortPasswordAndForeignFilesFailClearly() throws {
        let data = try SignInTransferFile.seal(payload, password: "correct horse", rounds: 1_000)
        XCTAssertThrowsError(try SignInTransferFile.open(data, password: "wrong horse")) {
            XCTAssertEqual($0 as? SignInTransferError, .wrongPassword)
        }
        XCTAssertThrowsError(try SignInTransferFile.seal(payload, password: "short")) {
            XCTAssertEqual($0 as? SignInTransferError, .passwordTooShort)
        }
        XCTAssertThrowsError(try SignInTransferFile.open(Data(#"{"hello":"world"}"#.utf8), password: "correct horse")) {
            XCTAssertEqual($0 as? SignInTransferError, .unrecognizedFile)
        }
    }
}

@MainActor
final class SignInFallbackTests: XCTestCase {
    func testOnlyAMissingOrRejectedLocalLoginHandsOverToTheSignIn() {
        let provider = GrokProvider().provider
        func snapshot(_ category: ErrorCategory) -> ProviderSnapshot {
            ProviderSnapshot.error(provider: provider, message: "x", category: category)
        }
        XCTAssertTrue(SignInFallback.localLoginMissing(snapshot(.notLoggedIn)))
        XCTAssertTrue(SignInFallback.localLoginMissing(snapshot(.authExpired)))
        XCTAssertFalse(SignInFallback.localLoginMissing(snapshot(.network)))
        XCTAssertFalse(SignInFallback.localLoginMissing(snapshot(.rateLimited)))
    }
}

/// Only reports which services exist; never hands out a secret.
private struct ExistingItemsKeychain: KeychainAccessing {
    let services: Set<String>
    func readGenericPassword(service: String) throws -> String? { XCTFail("must not read a secret"); return nil }
    func writeGenericPassword(service: String, value: String) throws { XCTFail("must not write") }
    func genericPasswordExists(service: String) -> Bool? { services.contains(service) }
}

/// Regression: a Claude Code login under cac's `CLAUDE_CONFIG_DIR` looked missing after a restart,
/// because a Finder-launched OpenUsage never sees that variable.
final class ClaudeConfigDirDiscoveryTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("openusage-cac-\(UUID().uuidString)")
        for env in ["other", "work"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".cac/envs/\(env)/.claude"), withIntermediateDirectories: true)
        }
        try "work\n".write(to: home.appendingPathComponent(".cac/current"), atomically: true, encoding: .utf8)
        suite = "ClaudeConfigDir.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    private func service(_ directory: String) -> String {
        "Claude Code-credentials-\(ClaudeAuthStore.configDirHash(directory))"
    }

    func testFindsTheActiveCacEnvironmentsLoginAndRemembersIt() {
        let work = home.path + "/.cac/envs/work/.claude"
        let other = home.path + "/.cac/envs/other/.claude"
        let keychain = ExistingItemsKeychain(services: [service(work), service(other)])

        let found = ClaudeConfigDirDiscovery.discover(defaults: defaults, home: home.path, keychain: keychain)

        XCTAssertEqual(found, work)
        XCTAssertEqual(defaults.string(forKey: ClaudeConfigDirDiscovery.defaultsKey), work)
    }

    func testDefaultLoginOrNoLoginLeavesTheEnvironmentAlone() {
        let work = home.path + "/.cac/envs/work/.claude"
        let withDefault = ExistingItemsKeychain(services: ["Claude Code-credentials", service(work)])
        XCTAssertNil(ClaudeConfigDirDiscovery.discover(defaults: defaults, home: home.path, keychain: withDefault))
        XCTAssertNil(ClaudeConfigDirDiscovery.discover(
            defaults: defaults, home: home.path, keychain: ExistingItemsKeychain(services: [])))
        XCTAssertNil(defaults.string(forKey: ClaudeConfigDirDiscovery.defaultsKey))
    }
}
