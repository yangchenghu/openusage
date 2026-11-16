import Foundation
import Observation

/// One provider's in-app sign-in state for the UI: who is signed in, and the progress of a sign-in in
/// flight (the browser page or device code to show, a code the user pastes back, errors).
///
/// App-owned, so closing the menu panel while the browser is open doesn't cancel the sign-in. The
/// provider's auth store reads the same `store` on every refresh; this session only changes it.
@MainActor
@Observable
final class SignInSession {
    let providerID: String
    @ObservationIgnored let store: any SignedInAccountStoring
    @ObservationIgnored private let signIn: any ProviderSignIn

    private(set) var account: SignedInAccount?
    private(set) var isLoaded = false
    private(set) var isSigningIn = false
    private(set) var prompt: LoginPrompt?
    private(set) var errorMessage: String?

    /// Called after a sign-in or sign-out changed the stored account (`true` = now signed in).
    @ObservationIgnored var onAccountChanged: (@MainActor (Bool) async -> Void)?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var pastedCode: AsyncStream<String>.Continuation?

    init(providerID: String, store: any SignedInAccountStoring, signIn: any ProviderSignIn) {
        self.providerID = providerID
        self.store = store
        self.signIn = signIn
    }

    var isSignedIn: Bool { account != nil }

    func load() async {
        do {
            account = try await loadOffMainActor { [store] in try store.load() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoaded = true
    }

    func startSignIn(openURL: @escaping @MainActor (URL) -> Void) {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        prompt = nil
        let (codes, continuation) = AsyncStream.makeStream(of: String.self)
        pastedCode = continuation
        loginTask = Task {
            defer {
                isSigningIn = false
                prompt = nil
                pastedCode?.finish()
                pastedCode = nil
                loginTask = nil
            }
            do {
                let signedIn = try await signIn.login(prompt: { [weak self] next in
                    await MainActor.run {
                        self?.prompt = next
                        switch next {
                        case .browser(let url, _): openURL(url)
                        case .deviceCode(_, let url): openURL(url)
                        }
                    }
                }, pastedCode: codes)
                try Task.checkCancellation()
                try await loadOffMainActor { [store] in try store.save(signedIn) }
                account = signedIn
                AppLog.info(LogTag.auth(providerID), "signed in inside OpenUsage")
                await onAccountChanged?(true)
            } catch is CancellationError {
                // Cancelled by the user; the previous state stays.
            } catch LoginError.cancelled {
                // Same, surfaced by the callback listener.
            } catch {
                errorMessage = error.localizedDescription
                AppLog.error(LogTag.auth(providerID), "sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    /// A code (or the whole callback URL) the user copied from the provider's page.
    func submitPastedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pastedCode?.yield(trimmed)
    }

    func cancelSignIn() {
        loginTask?.cancel()
    }

    func signOut() async {
        errorMessage = nil
        do {
            try await loadOffMainActor { [store] in try store.delete() }
            account = nil
            AppLog.info(LogTag.auth(providerID), "signed out of OpenUsage sign-in")
            await onAccountChanged?(false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves an account exported from another Mac as this card's sign-in. The caller turns the card on.
    func adopt(_ imported: SignedInAccount) async throws {
        try await loadOffMainActor { [store] in try store.save(imported) }
        account = imported
        errorMessage = nil
        isLoaded = true
        AppLog.info(LogTag.auth(providerID), "imported an OpenUsage sign-in")
    }

    /// Re-reads the store after a refresh renewed (or a provider rejected) the tokens, so the UI shows
    /// the current state.
    func reload() async {
        await load()
    }
}
