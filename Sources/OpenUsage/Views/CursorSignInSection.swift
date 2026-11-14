import AppKit
import SwiftUI

struct CursorSignInSection: View {
    let session: CursorAccountSession
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Account")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderIcon(source: .providerMark("cursor"))
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.account?.label ?? "Cursor")
                            .lineLimit(1)
                        Text(session.isSigningIn ? "Finish signing in in your browser." :
                            session.account == nil ? "Using Cursor App Login" : "Signed In With OpenUsage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if session.isSigningIn {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { session.cancelSignIn() }
                    } else {
                        Button(session.account == nil ? "Sign In…" : "Sign In Again…") {
                            session.startSignIn(openBrowser: { NSWorkspace.shared.open($0) }, onComplete: refresh)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if session.isSigningIn, let url = session.authorizationURL {
                    Button("Open Browser Again") { NSWorkspace.shared.open(url) }
                        .font(.caption)
                } else if session.account != nil {
                    Button("Use Cursor App Login") {
                        Task {
                            do {
                                try await session.useCursorAppLogin()
                                loadError = nil
                                await refresh()
                            } catch {
                                loadError = error.localizedDescription
                                AppLog.error(LogTag.auth("cursor"), "could not remove OpenUsage's saved sign-in")
                            }
                        }
                    }
                    .font(.caption)
                }
                if let error = session.errorMessage ?? loadError ?? session.persistenceWarning {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
            .cardSurface()
        }
        .task {
            do { _ = try await session.loadAuthState() }
            catch { loadError = error.localizedDescription }
        }
    }

    @MainActor
    private func refresh() async {
        container.dataStore.providerAccountDidChange("cursor")
        container.enablement.setEnabled(true, for: "cursor")
        container.dataStore.clearFailureBackoff(for: "cursor")
        await container.dataStore.refresh(providerID: "cursor", force: true)
    }
}
