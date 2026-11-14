import Foundation

/// Normalizes OKX quotes into metric lines: per coin, a price row (last price + 24h change) and a 24h
/// range row (low then high, rendered as a span "low – high" so it fits the 320pt panel). Line labels
/// are the stable keys the widget descriptors match on.
enum CryptoPriceMapper {
    static func priceLabel(for coin: String) -> String { coin }
    static func rangeLabel(for coin: String) -> String { "\(coin) 24h Range" }

    static let unlistedText = "Not Listed"

    /// Lines in the configured coin order. An unlisted coin gets a "Not Listed" badge on its price row
    /// (and no range row, so that tile reads "No data"); a coin whose request failed gets no lines at
    /// all, keeping the rest of the card intact.
    static func lines(coins: [String], results: [String: CryptoQuoteResult]) -> [MetricLine] {
        var lines: [MetricLine] = []
        for coin in coins {
            switch results[coin] {
            case .quote(let ticker):
                var priceValues = [MetricValue(number: ticker.last, kind: .price)]
                if let change = ticker.change24hPercent {
                    priceValues.append(MetricValue(number: change, kind: .change))
                }
                lines.append(.values(label: priceLabel(for: coin), values: priceValues))
                lines.append(.values(label: rangeLabel(for: coin), values: [
                    MetricValue(number: ticker.low24h, kind: .price),
                    MetricValue(number: ticker.high24h, kind: .price)
                ]))
            case .unlisted:
                lines.append(.badge(label: priceLabel(for: coin), text: unlistedText))
            case .failed, nil:
                continue
            }
        }
        return lines
    }

    /// The error to surface when no coin produced a quote: the first failure in coin order, so the
    /// message is stable from one refresh to the next. `nil` when at least one coin answered (quoted or
    /// unlisted) — a partial outage keeps the card's good rows instead of blanking it.
    static func blockingError(coins: [String], results: [String: CryptoQuoteResult]) -> CryptoPriceError? {
        var firstFailure: CryptoPriceError?
        for coin in coins {
            switch results[coin] {
            case .quote, .unlisted:
                return nil
            case .failed(let error):
                if firstFailure == nil { firstFailure = error }
            case nil:
                if firstFailure == nil { firstFailure = .invalidResponse }
            }
        }
        return firstFailure
    }
}
