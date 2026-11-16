import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Sign-In Transfer: exports OpenUsage's own sign-ins to a password-protected file and
/// imports one on another Mac, so a provider signed in once doesn't need signing in again.
struct SignInTransferSection: View {
    private enum Action { case export, `import` }

    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var action: Action?
    @State private var password = ""
    @State private var isWorking = false
    @State private var result: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Sign-In Transfer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                if let action {
                    passwordRows(for: action)
                } else {
                    fullWidthButton("Export Sign-Ins…") { begin(.export) }
                    fullWidthButton("Import Sign-Ins…") { begin(.import) }
                }
                caption(
                    "Copies sign-ins made with OpenUsage Sign-In (not local logins) in a password-protected file. "
                        + "Providers renew sign-ins with single-use tokens, so using one sign-in on two Macs at once can sign one of them out.",
                    color: .secondary
                )
                if let result { caption(result, color: .secondary) }
                if let errorMessage { caption(errorMessage, color: Theme.notice) }
            }
            .cardSurface()
        }
    }

    @ViewBuilder
    private func passwordRows(for action: Action) -> some View {
        SecureField("Password", text: $password, prompt: Text("File Password"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .onSubmit { run(action) }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
        HStack(spacing: 8) {
            if isWorking { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            Button("Cancel") { self.action = nil; password = "" }
                .controlSize(.small)
                .disabled(isWorking)
            Button(action == .export ? "Export…" : "Import…") { run(action) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking || password.count < SignInTransferFile.minimumPasswordLength)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func begin(_ next: Action) {
        result = nil
        errorMessage = nil
        password = ""
        action = next
    }

    private func run(_ action: Action) {
        guard !isWorking, password.count >= SignInTransferFile.minimumPasswordLength else { return }
        isWorking = true
        errorMessage = nil
        result = nil
        let password = password
        Task {
            defer { isWorking = false }
            do {
                switch action {
                case .export:
                    let data = try await container.exportSignIns(password: password)
                    guard let url = await TransferFilePanel.chooseExportDestination() else { return }
                    try data.write(to: url, options: .atomic)
                    result = "Exported to \(url.lastPathComponent). Import it in Settings on your other Mac."
                case .import:
                    guard let url = await TransferFilePanel.chooseImportFile() else { return }
                    let data = try Data(contentsOf: url)
                    let names = try await container.importSignIns(data, password: password)
                    result = "Imported sign-ins for \(names.joined(separator: ", "))."
                }
                self.action = nil
                self.password = ""
            } catch {
                errorMessage = error.localizedDescription
                AppLog.error(.config, "sign-in transfer failed: \(error.localizedDescription)")
            }
        }
    }

    private func fullWidthButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func caption(_ text: String, color: some ShapeStyle) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Save/open panels for the transfer file. Shown as a sheet on the menu-bar panel so the panel stays
/// open while the file dialog is up (outside-click dismissal ignores clicks while a sheet is attached).
@MainActor
private enum TransferFilePanel {
    static func chooseExportDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenUsage Sign-Ins.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return await present(panel)
    }

    static func chooseImportFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return await present(panel)
    }

    private static func present(_ panel: NSSavePanel) async -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        guard let host = NSApp.windows.first(where: { $0 is MenuBarPanel && $0.isVisible }) else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: host) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
