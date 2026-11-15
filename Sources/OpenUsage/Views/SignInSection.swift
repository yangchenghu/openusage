import AppKit
import SwiftUI

/// The "Account" card in a provider's Customize detail: who is signed in, with the same login/logout
/// action as the provider's row in the Customize list. Signing in turns the provider on; signing out
/// turns it off.
struct SignInSection: View {
    let session: SignInSession
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Account")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                statusRow
                if session.isSigningIn || session.errorMessage != nil {
                    Divider()
                    SignInPromptView(session: session)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Rectangle().fill(.fill.quinary))
                }
            }
            .cardSurface()
            .clipShape(Theme.cardShape)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.account?.label ?? "Not Signed In")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.isSignedIn ? "Signed in to OpenUsage" : "Sign in to turn this provider on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if session.isSigningIn {
                ProgressView().controlSize(.mini)
            }
            Button(session.actionTitle) { session.performPrimaryAction() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.isLoaded)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}

/// What a sign-in in flight asks of the user — the browser step (with a paste-code fallback) or a
/// device code — plus the latest error. Shared by the Account card and the list row's popover.
struct SignInPromptView: View {
    let session: SignInSession
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.prompt {
            case .browser(let url, let acceptsPastedCode):
                Text("Finish signing in in your browser, or copy the link to open it in another browser on this Mac.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Open Browser Again") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    CopyLinkButton(url: url)
                }
                if acceptsPastedCode {
                    Text("If the page shows a code instead, paste it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Code", text: $pasted, prompt: Text("Paste Code"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit(submit)
                        Button("Submit", action: submit)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            case .deviceCode(let userCode, let url):
                Text("Enter this code on the page that opened:")
                    .font(.caption)
                HStack(spacing: 8) {
                    Text(userCode)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(userCode, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                HStack(spacing: 12) {
                    Button("Open Page Again") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    CopyLinkButton(url: url)
                }
            case nil:
                if session.isSigningIn {
                    Text("Starting sign-in…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: session.isSigningIn) { _, _ in pasted = "" }
    }

    private func submit() {
        session.submitPastedCode(pasted)
        pasted = ""
    }
}

/// Copies a sign-in link so it can be opened in a browser other than the default one; the label
/// briefly confirms the copy.
struct CopyLinkButton: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .buttonStyle(.link)
        .controlSize(.small)
    }
}

/// The list row's login/logout control (replacing the on/off toggle, like Cursor's): a spinner while
/// busy, and a status button whose popover carries the sign-in prompt or the latest error.
struct SignInAccountControl: View {
    let session: SignInSession
    @State private var showsPrompt = false

    var body: some View {
        HStack(spacing: 6) {
            if session.isSigningIn || !session.isLoaded {
                ProgressView().controlSize(.mini)
            }
            Button(session.isSigningIn ? "Cancel" : session.isSignedIn ? "logout" : "login") {
                session.performPrimaryAction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!session.isLoaded)
            if session.isSigningIn || session.errorMessage != nil {
                Button { showsPrompt.toggle() } label: {
                    Image(systemName: session.errorMessage == nil ? "arrow.up.right" : "exclamationmark.circle")
                        .foregroundStyle(session.errorMessage == nil ? AnyShapeStyle(Color.secondary) : Theme.notice)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sign-In Status")
                .popover(isPresented: $showsPrompt) {
                    SignInPromptView(session: session)
                        .padding(12)
                        .frame(width: 260, alignment: .leading)
                }
            }
        }
        // Device codes and paste fields need the popover, so open it as soon as the prompt arrives;
        // errors open it too, like Cursor's control.
        .onChange(of: session.prompt) { _, prompt in
            if case .deviceCode = prompt { showsPrompt = true }
        }
        .onChange(of: session.errorMessage) { _, message in
            if message != nil { showsPrompt = true }
        }
        .onChange(of: session.isSigningIn) { _, signingIn in
            if !signingIn, session.errorMessage == nil { showsPrompt = false }
        }
    }
}

extension SignInSession {
    var actionTitle: String {
        if isSigningIn { return "Cancel" }
        return isSignedIn ? "Sign Out" : "Sign In"
    }

    func performPrimaryAction() {
        if isSigningIn {
            cancelSignIn()
        } else if isSignedIn {
            Task { await signOut() }
        } else {
            startSignIn(openURL: { NSWorkspace.shared.open($0) })
        }
    }
}
