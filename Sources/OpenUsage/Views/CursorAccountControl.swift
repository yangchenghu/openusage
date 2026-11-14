import AppKit
import SwiftUI

/// Cursor's login replaces its enablement toggle; credentials and enablement change together.
struct CursorAccountControl: View {
    let session: CursorAccountSession
    @Environment(AppContainer.self) private var container
    @State private var isLoading = true
    @State private var isLoggingOut = false
    @State private var actionError: String?
    @State private var showsFeedback = false

    var body: some View {
        HStack(spacing: 6) {
            if session.isSigningIn || isLoading || isLoggingOut {
                ProgressView().controlSize(.mini)
            }
            Button(session.isSigningIn ? "Cancel" : session.account == nil ? "login" : "logout") {
                actionError = nil
                if session.isSigningIn {
                    session.cancelSignIn()
                } else if session.account != nil {
                    logout()
                } else {
                    session.startSignIn(openBrowser: { NSWorkspace.shared.open($0) }, onComplete: refreshAfterLogin)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading || isLoggingOut)
            if feedback != nil || session.isSigningIn {
                Button { showsFeedback.toggle() } label: {
                    Image(systemName: feedback == nil ? "arrow.up.right" : "exclamationmark.circle")
                        .foregroundStyle(feedback == nil ? AnyShapeStyle(Color.secondary) : Theme.notice)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cursor Sign-In Status")
                .popover(isPresented: $showsFeedback) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let feedback {
                            Text(feedback).foregroundStyle(Theme.notice)
                        } else {
                            Text("Finish signing in in your browser.")
                        }
                        if session.isSigningIn, let url = session.authorizationURL {
                            Button("Open Browser Again") { NSWorkspace.shared.open(url) }
                        }
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(width: 240, alignment: .leading)
                }
            }
        }
        .task {
            defer { isLoading = false }
            do {
                _ = try await session.loadAuthState()
            } catch {
                actionError = error.localizedDescription
                AppLog.error(LogTag.auth("cursor"), "could not load Cursor login status")
            }
        }
        .onChange(of: feedback) { _, message in showsFeedback = message != nil }
    }

    private var feedback: String? { actionError ?? session.errorMessage ?? session.persistenceWarning }

    private func logout() {
        isLoggingOut = true
        Task {
            defer { isLoggingOut = false }
            do {
                try await session.signOut()
                container.enablement.setEnabled(false, for: "cursor")
                container.dataStore.providerAccountDidChange("cursor")
            } catch {
                actionError = error.localizedDescription
                AppLog.error(LogTag.auth("cursor"), "could not log out of Cursor")
            }
        }
    }

    @MainActor
    private func refreshAfterLogin() async {
        container.dataStore.providerAccountDidChange("cursor")
        container.enablement.setEnabled(true, for: "cursor")
        await container.dataStore.refresh(providerID: "cursor", force: true)
    }
}
