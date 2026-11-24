import Foundation

/// One symbol's current trading day from Yahoo's chart endpoint: the last price, the previous session's
/// close, and today's high and low.
struct DollarIndexQuote: Equatable, Sendable {
    let price: Double
    let previousClose: Double?
    let dayHigh: Double
    let dayLow: Double

    /// The change against the previous close in percent, or `nil` without a previous close to compare.
    var changePercent: Double? {
        guard let previousClose, previousClose != 0 else { return nil }
        return (price / previousClose - 1) * 100
    }
}

/// Reads Yahoo Finance's public chart endpoint for one symbol.
///
/// `range=1d` makes `chartPreviousClose` the prior session's close, so the change matches what quote
/// pages show (a wider range would compare against the close before the whole window). Yahoo rejects
/// requests without a browser-like User-Agent with HTTP 429, so one is always sent.
struct YahooChartClient: Sendable {
    static let apiBase = "https://query1.finance.yahoo.com"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    static func url(symbol: String) -> URL? {
        var components = URLComponents(string: apiBase + "/v8/finance/chart/" + symbol)
        components?.queryItems = [
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "range", value: "1d")
        ]
        return components?.url
    }

    func fetchQuote(symbol: String) async throws(DollarIndexError) -> DollarIndexQuote {
        guard let url = Self.url(symbol: symbol) else { throw .invalidResponse }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET", url: url,
                headers: ["Accept": "application/json", "User-Agent": Self.userAgent],
                timeout: 10
            ))
        } catch {
            AppLog.warn(LogTag.plugin("dxy"), "\(symbol) request failed: \(error.localizedDescription)")
            throw .connectionFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("dxy"), "\(symbol) HTTP \(response.statusCode)")
            throw .requestFailed(response.statusCode)
        }
        return try Self.parse(response.body, symbol: symbol)
    }

    /// Parses one `/v8/finance/chart` body. The quote lives in `chart.result[0].meta`; a failure carries
    /// `chart.error.code` with a null result.
    static func parse(_ body: Data, symbol: String) throws(DollarIndexError) -> DollarIndexQuote {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let chart = root["chart"] as? [String: Any]
        else { throw .invalidResponse }
        if let error = chart["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "unknown"
            AppLog.warn(LogTag.plugin("dxy"), "\(symbol) Yahoo error \(code): \(error["description"] as? String ?? "")")
            throw .apiError(code)
        }
        guard let meta = (chart["result"] as? [[String: Any]])?.first?["meta"] as? [String: Any],
              let price = number(meta["regularMarketPrice"]),
              let high = number(meta["regularMarketDayHigh"]),
              let low = number(meta["regularMarketDayLow"])
        else { throw .invalidResponse }
        return DollarIndexQuote(
            price: price,
            previousClose: number(meta["chartPreviousClose"]),
            dayHigh: high,
            dayLow: low
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return number
    }
}

enum DollarIndexError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach Yahoo Finance. Check your network or proxy."
        case .invalidResponse:
            return "Yahoo Finance returned data in an unexpected format. Try again later."
        case .requestFailed(429):
            return "Yahoo Finance is rate limiting requests. It will retry shortly."
        case .requestFailed(let status):
            return "Yahoo Finance request failed (HTTP \(status))."
        case .apiError(let code):
            return "Yahoo Finance returned error \(code)."
        }
    }
}
