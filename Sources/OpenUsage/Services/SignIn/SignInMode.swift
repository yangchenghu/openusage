import Foundation
import Observation

/// How a login-gated card (Claude, Codex, Cursor, Grok) gets its credentials: from the tool already
/// logged in on this Mac, or from OpenUsage's own sign-in (which can be exported to another Mac).
enum SignInMode: String, CaseIterable, Sendable {
    case local
    case openUsage

    var label: String {
        switch self {
        case .local: "Local Login"
        case .openUsage: "OpenUsage Sign-In"
        }
    }

    static func key(for providerID: String) -> String { "openusage.signInMode.\(providerID)" }

    /// The stored choice, or `nil` when the user (or the launch migration) never picked one.
    static func stored(for providerID: String, defaults: UserDefaults = .standard) -> SignInMode? {
        defaults.string(forKey: key(for: providerID)).flatMap(SignInMode.init(rawValue:))
    }
}

/// A live, thread-safe answer to "is this card using its OpenUsage sign-in right now?", read by the
/// auth stores on every refresh so switching modes needs no provider rebuild.
struct SignInModeReader: Sendable {
    private let read: @Sendable () -> Bool

    init(_ read: @escaping @Sendable () -> Bool) {
        self.read = read
    }

    var usesSignIn: Bool { read() }

    /// Always the sign-in; tests and callers that pass a store and mean "gated".
    static let always = SignInModeReader { true }

    /// The card's persisted choice. Unset reads as local login, like before in-app sign-in existed.
    static func stored(providerID: String, defaults: UserDefaults = .standard) -> SignInModeReader {
        let box = DefaultsBox(defaults: defaults)
        return SignInModeReader { SignInMode.stored(for: providerID, defaults: box.defaults) == .openUsage }
    }
}

/// `UserDefaults` is documented thread-safe but isn't annotated `Sendable` in the SDK.
private struct DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
}

/// The observable copy of each card's mode for the UI. Writes go straight to `UserDefaults`, which is
/// what `SignInModeReader` reads on the refresh path.
@MainActor
@Observable
final class SignInModeStore {
    private(set) var modes: [String: SignInMode] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(providerIDs: [String], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for id in providerIDs {
            if let mode = SignInMode.stored(for: id, defaults: defaults) { modes[id] = mode }
        }
    }

    func mode(for providerID: String) -> SignInMode { modes[providerID] ?? .local }

    func hasStoredMode(for providerID: String) -> Bool { modes[providerID] != nil }

    func set(_ mode: SignInMode, for providerID: String) {
        defaults.set(mode.rawValue, forKey: SignInMode.key(for: providerID))
        modes[providerID] = mode
    }
}
