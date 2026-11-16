import os
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
final class SignInModeTests: XCTestCase {
    func testStoredModeDefaultsToLocalLogin() throws {
        let suite = "SignInMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = SignInModeReader.stored(providerID: "claude", defaults: defaults)
        XCTAssertFalse(reader.usesSignIn)

        let store = SignInModeStore(providerIDs: ["claude"], defaults: defaults)
        XCTAssertFalse(store.hasStoredMode(for: "claude"))
        store.set(.openUsage, for: "claude")
        XCTAssertTrue(reader.usesSignIn)
        XCTAssertEqual(SignInModeStore(providerIDs: ["claude"], defaults: defaults).mode(for: "claude"), .openUsage)
    }

    /// Switching the method takes effect on the next read, without rebuilding the provider.
    func testLocalLoginReadsTheCLIAndSwitchesLive() async {
        let usesSignIn = OSAllocatedUnfairLock(initialState: false)
        let grok = GrokProvider(
            authStore: GrokAuthStore(files: FakeFiles(["~/.grok/auth.json": #"{"cli":{"key":"grok-cli-token"}}"#])),
            signIn: InMemorySignInStore(),
            signInMode: SignInModeReader { usesSignIn.withLock { $0 } }
        )
        XCTAssertFalse(grok.requiresOpenUsageSignIn)
        let localDetected = await grok.hasLocalCredentials()
        XCTAssertTrue(localDetected, "local login reads the Grok CLI's auth")

        usesSignIn.withLock { $0 = true }
        XCTAssertTrue(grok.requiresOpenUsageSignIn)
        let signInDetected = await grok.hasLocalCredentials()
        XCTAssertFalse(signInDetected, "OpenUsage Sign-In ignores the CLI's login")
    }
}
