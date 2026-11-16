import SwiftUI

/// The "Login Method" card in a login-gated provider's Customize detail: read the tool already logged
/// in on this Mac, or use OpenUsage's own sign-in (which Settings can export to another Mac).
struct LoginMethodSection: View {
    let providerID: String
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Login Method")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Source")
                    Spacer(minLength: 8)
                    Picker("", selection: selection) {
                        ForEach(SignInMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .cardSurface()
        }
    }

    private var selection: Binding<SignInMode> {
        Binding(
            get: { container.signInModes.mode(for: providerID) },
            set: { container.setLoginMethod($0, for: providerID) }
        )
    }

    private var caption: String {
        switch container.signInModes.mode(for: providerID) {
        case .local:
            "Uses the login already on this Mac. Turn the provider on or off with its toggle."
        case .openUsage:
            "Uses a sign-in kept by OpenUsage. Export it in Settings to use it on another Mac."
        }
    }
}
