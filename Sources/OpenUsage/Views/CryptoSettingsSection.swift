import SwiftUI

/// Crypto Prices' configuration card in its Customize detail: the coins to quote and the OKX API
/// address. The coin list decides which tiles exist, so a change is saved and applied by restarting.
struct CryptoSettingsSection: View {
    /// The settings the running app was launched with (what the tiles currently reflect).
    let applied: CryptoPriceSettings
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @State private var coinsInput = ""
    @State private var apiBaseInput = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Coins")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                field("Coins", text: $coinsInput, prompt: "BTC ETH SOL")
                Text("Quoted against \(CryptoPriceSettings.quoteCurrency) on the spot market. Separate coins with spaces or commas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                field("API Address", text: $apiBaseInput, prompt: CryptoPriceSettings.defaultAPIBase)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                }
                HStack(spacing: 8) {
                    Button("Apply & Restart") { apply() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!hasChanges)
                    Button("Use Defaults") { useDefaults() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .onAppear { load(applied) }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onChange(of: text.wrappedValue) { _, _ in errorMessage = nil }
        }
    }

    private var hasChanges: Bool {
        guard let parsed = try? parsedSettings() else { return true }
        return parsed != applied
    }

    private func parsedSettings() throws -> CryptoPriceSettings {
        CryptoPriceSettings(
            coins: try CryptoPriceSettings.parseCoins(coinsInput),
            apiBase: try CryptoPriceSettings.parseAPIBase(apiBaseInput)
        )
    }

    private func load(_ settings: CryptoPriceSettings) {
        coinsInput = settings.coins.joined(separator: " ")
        apiBaseInput = settings.apiBase
        errorMessage = nil
    }

    private func useDefaults() {
        load(CryptoPriceSettings())
    }

    private func apply() {
        let settings: CryptoPriceSettings
        do {
            settings = try parsedSettings()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        settings.save()
        AppLog.info(LogTag.plugin("crypto"), "settings saved (\(settings.coins.count) coins)")
        do {
            try AppRelauncher.relaunch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
