import Foundation

/// The Crypto Prices plugin's user configuration: which coins to quote (against USDT) and which OKX
/// API host to ask. Persisted in `UserDefaults`; the provider reads it once at launch because the coin
/// list decides the widget descriptors, so a change applies on the next launch (Customize offers an
/// Apply & Restart button for exactly that).
struct CryptoPriceSettings: Equatable, Sendable {
    static let defaultCoins = ["BTC", "ETH", "SOL", "GRAM", "HYPE", "PEPE", "OKB", "XAUT"]
    static let defaultAPIBase = "https://www.okx.com"
    static let quoteCurrency = "USDT"

    static let coinsKey = "openusage.crypto.coins.v1"
    static let apiBaseKey = "openusage.crypto.apiBase.v1"

    var coins: [String]
    var apiBase: String

    init(coins: [String] = Self.defaultCoins, apiBase: String = Self.defaultAPIBase) {
        self.coins = coins
        self.apiBase = apiBase
    }

    static func load(from defaults: UserDefaults = .standard) -> CryptoPriceSettings {
        let storedCoins = defaults.stringArray(forKey: coinsKey)
        let storedBase = defaults.string(forKey: apiBaseKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CryptoPriceSettings(
            coins: storedCoins ?? defaultCoins,
            apiBase: storedBase.flatMap { $0.isEmpty ? nil : $0 } ?? defaultAPIBase
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(coins, forKey: Self.coinsKey)
        defaults.set(apiBase, forKey: Self.apiBaseKey)
    }

    /// Parses the coin field the user typed: separated by spaces, commas, or newlines; case-insensitive;
    /// `BTC`, `btc/usdt`, and `BTC-USDT` all mean the BTC/USDT spot pair. Duplicates collapse, order is
    /// kept. Throws on the first token that isn't a plain alphanumeric ticker, naming it, so the user
    /// sees exactly what to fix instead of a silently dropped coin.
    static func parseCoins(_ input: String) throws -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))
        var seen = Set<String>()
        var coins: [String] = []
        for token in input.components(separatedBy: separators) where !token.isEmpty {
            var coin = token.uppercased()
            for suffix in ["/\(quoteCurrency)", "-\(quoteCurrency)"] where coin.hasSuffix(suffix) {
                coin.removeLast(suffix.count)
            }
            guard !coin.isEmpty, coin.unicodeScalars.allSatisfy(Self.isTickerScalar) else {
                throw CryptoSettingsError.invalidCoin(token)
            }
            if seen.insert(coin).inserted { coins.append(coin) }
        }
        guard !coins.isEmpty else { throw CryptoSettingsError.noCoins }
        return coins
    }

    /// Validates the API host: an absolute http(s) URL with a host. The trailing slash is dropped so the
    /// client can append its path.
    static func parseAPIBase(_ input: String) throws -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { throw CryptoSettingsError.invalidAPIBase(input) }
        return trimmed
    }

    private static func isTickerScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

enum CryptoSettingsError: Error, LocalizedError, Equatable {
    case invalidCoin(String)
    case noCoins
    case invalidAPIBase(String)

    var errorDescription: String? {
        switch self {
        case .invalidCoin(let token):
            return "“\(token)” isn't a valid coin. Use letters and digits only, like BTC or ETH/USDT."
        case .noCoins:
            return "Add at least one coin."
        case .invalidAPIBase:
            return "Enter a full http(s) address, like https://www.okx.com."
        }
    }
}
