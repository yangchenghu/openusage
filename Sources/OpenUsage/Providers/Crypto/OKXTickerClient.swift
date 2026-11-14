import Foundation

/// One coin's 24h spot ticker against USDT, parsed from OKX's string-encoded numbers.
struct CryptoTicker: Equatable, Sendable {
    let coin: String
    let last: Double
    let open24h: Double
    let high24h: Double
    let low24h: Double

    /// The 24h change in percent, or `nil` when there's no opening price to compare against.
    var change24hPercent: Double? {
        guard open24h != 0 else { return nil }
        return (last / open24h - 1) * 100
    }
}

/// What OKX said about one coin.
enum CryptoQuoteResult: Equatable, Sendable {
    case quote(CryptoTicker)
    /// OKX has no USDT spot pair for this coin (error 51001) — a normal answer, not a malfunction.
    case unlisted
    case failed(CryptoPriceError)
}

/// Reads OKX's public spot ticker, one request per coin.
///
/// Per-coin rather than the all-spot `/market/tickers` list a one-off script would use: that list is
/// ~390 KB, which at a 15-second cadence is gigabytes a day, while a single ticker is a few hundred
/// bytes. The coins are fetched concurrently, well under OKX's public rate limit (20 requests / 2 s).
struct OKXTickerClient: Sendable {
    static let unlistedCode = "51001"

    var apiBase: String
    var http: any HTTPClient

    init(apiBase: String = CryptoPriceSettings.defaultAPIBase, http: any HTTPClient = URLSessionHTTPClient()) {
        self.apiBase = apiBase
        self.http = http
    }

    func fetchQuotes(coins: [String]) async -> [String: CryptoQuoteResult] {
        await withTaskGroup(of: (String, CryptoQuoteResult).self) { group in
            for coin in coins {
                group.addTask { (coin, await fetchQuote(coin: coin)) }
            }
            var results: [String: CryptoQuoteResult] = [:]
            for await (coin, result) in group { results[coin] = result }
            return results
        }
    }

    func fetchQuote(coin: String) async -> CryptoQuoteResult {
        let instID = "\(coin)-\(CryptoPriceSettings.quoteCurrency)"
        guard var components = URLComponents(string: apiBase + "/api/v5/market/ticker") else {
            return .failed(.invalidAPIBase)
        }
        components.queryItems = [URLQueryItem(name: "instId", value: instID)]
        guard let url = components.url else { return .failed(.invalidAPIBase) }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET", url: url, headers: ["Accept": "application/json"], timeout: 10
            ))
        } catch {
            AppLog.warn(LogTag.plugin("crypto"), "\(instID) request failed: \(error.localizedDescription)")
            return .failed(.connectionFailed)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("crypto"), "\(instID) HTTP \(response.statusCode)")
            return .failed(.requestFailed(response.statusCode))
        }
        return Self.parse(response.body, coin: coin)
    }

    /// Parses one `/market/ticker` body. OKX answers HTTP 200 even for errors, carrying the outcome in
    /// `code`: "0" with one ticker, or 51001 for an instrument that doesn't exist.
    static func parse(_ body: Data, coin: String) -> CryptoQuoteResult {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = root["code"] as? String
        else { return .failed(.invalidResponse) }
        if code == unlistedCode { return .unlisted }
        guard code == "0" else {
            AppLog.warn(LogTag.plugin("crypto"), "\(coin) OKX code \(code): \(root["msg"] as? String ?? "")")
            return .failed(.apiError(code))
        }
        guard let ticker = (root["data"] as? [[String: Any]])?.first,
              let last = number(ticker["last"]),
              let open = number(ticker["open24h"]),
              let high = number(ticker["high24h"]),
              let low = number(ticker["low24h"])
        else { return .failed(.invalidResponse) }
        return .quote(CryptoTicker(coin: coin, last: last, open24h: open, high24h: high, low24h: low))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let text = value as? String, let number = Double(text), number.isFinite else { return nil }
        return number
    }
}

enum CryptoPriceError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case invalidAPIBase
    case requestFailed(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach OKX. Check your network or proxy."
        case .invalidResponse:
            return "OKX returned data in an unexpected format. Try again later."
        case .invalidAPIBase:
            return "The OKX API address is invalid. Fix it in Customize → Crypto Prices."
        case .requestFailed(let status):
            return "OKX request failed (HTTP \(status))."
        case .apiError(let code):
            return "OKX returned error \(code)."
        }
    }
}
