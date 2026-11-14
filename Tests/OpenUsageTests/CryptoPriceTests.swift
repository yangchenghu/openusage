import XCTest
@testable import OpenUsage

/// Crypto Prices: coin parsing, OKX ticker parsing, line mapping, price formatting, and the provider's
/// refresh outcomes (full success, partial outage, total outage).
final class CryptoPriceSettingsTests: XCTestCase {
    func testParseCoinsAcceptsScriptFormatsAndDeduplicates() throws {
        XCTAssertEqual(
            try CryptoPriceSettings.parseCoins("btc eth/usdt, SOL-USDT\nBTC，pepe"),
            ["BTC", "ETH", "SOL", "PEPE"]
        )
    }

    func testParseCoinsRejectsInvalidTokensByName() {
        XCTAssertThrowsError(try CryptoPriceSettings.parseCoins("BTC E$H")) { error in
            XCTAssertEqual(error as? CryptoSettingsError, .invalidCoin("E$H"))
        }
        XCTAssertThrowsError(try CryptoPriceSettings.parseCoins("  , ")) { error in
            XCTAssertEqual(error as? CryptoSettingsError, .noCoins)
        }
    }

    func testParseAPIBaseRequiresHTTPURLAndDropsTrailingSlash() throws {
        XCTAssertEqual(try CryptoPriceSettings.parseAPIBase(" https://www.okx.com/ "), "https://www.okx.com")
        XCTAssertThrowsError(try CryptoPriceSettings.parseAPIBase("www.okx.com"))
        XCTAssertThrowsError(try CryptoPriceSettings.parseAPIBase("ftp://okx.com"))
    }

    func testLoadFallsBackToDefaultsAndRoundTrips() throws {
        let suite = "OpenUsageTests.Crypto.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CryptoPriceSettings.load(from: defaults), CryptoPriceSettings())
        let custom = CryptoPriceSettings(coins: ["DOGE"], apiBase: "https://example.com")
        custom.save(to: defaults)
        XCTAssertEqual(CryptoPriceSettings.load(from: defaults), custom)
    }
}

final class CryptoTickerParsingTests: XCTestCase {
    func testParsesTickerAndComputesChange() throws {
        let result = OKXTickerClient.parse(Self.tickerBody(last: "66481.7", open: "69427.9"), coin: "BTC")
        guard case .quote(let ticker) = result else { return XCTFail("expected a quote, got \(result)") }
        XCTAssertEqual(ticker.last, 66481.7)
        XCTAssertEqual(ticker.high24h, 69491.1)
        XCTAssertEqual(try XCTUnwrap(ticker.change24hPercent), -4.2435, accuracy: 0.0001)
    }

    func testZeroOpenHasNoChange() {
        guard case .quote(let ticker) = OKXTickerClient.parse(Self.tickerBody(last: "1", open: "0"), coin: "X")
        else { return XCTFail("expected a quote") }
        XCTAssertNil(ticker.change24hPercent)
    }

    func testUnlistedAndErrorCodes() {
        let unlisted = Data(#"{"code":"51001","data":[],"msg":"Instrument ID doesn't exist."}"#.utf8)
        XCTAssertEqual(OKXTickerClient.parse(unlisted, coin: "NOPE"), .unlisted)
        let limited = Data(#"{"code":"50011","data":[],"msg":"Too Many Requests"}"#.utf8)
        XCTAssertEqual(OKXTickerClient.parse(limited, coin: "BTC"), .failed(.apiError("50011")))
        XCTAssertEqual(OKXTickerClient.parse(Data("<html>".utf8), coin: "BTC"), .failed(.invalidResponse))
        let missingField = Data(#"{"code":"0","data":[{"last":"1"}]}"#.utf8)
        XCTAssertEqual(OKXTickerClient.parse(missingField, coin: "BTC"), .failed(.invalidResponse))
    }

    static func tickerBody(last: String, open: String, high: String = "69491.1", low: String = "66268.6") -> Data {
        Data(#"{"code":"0","msg":"","data":[{"instId":"X-USDT","last":"\#(last)","open24h":"\#(open)","high24h":"\#(high)","low24h":"\#(low)"}]}"#.utf8)
    }
}

final class CryptoPriceMapperTests: XCTestCase {
    private let btc = CryptoTicker(coin: "BTC", last: 66481.7, open24h: 69427.9, high24h: 69491.1, low24h: 66268.6)

    func testLinesFollowCoinOrderAndMarkUnlistedCoins() {
        let lines = CryptoPriceMapper.lines(
            coins: ["NOPE", "BTC", "DOWN"],
            results: ["BTC": .quote(btc), "NOPE": .unlisted, "DOWN": .failed(.connectionFailed)]
        )
        XCTAssertEqual(lines.map(\.label), ["NOPE", "BTC", "BTC 24h Range"])
        XCTAssertEqual(lines[0], .badge(label: "NOPE", text: CryptoPriceMapper.unlistedText))
        guard case .values(_, let values, _, _, _, _) = lines[1] else { return XCTFail("expected values") }
        XCTAssertEqual(values.map(\.kind), [.price, .change])
    }

    /// Regression: the expanded range row read "69,132.90 high · 65,813.00 low", which with its label
    /// overflowed the 320pt panel's 264pt content width and stretched the page. It is now a span.
    @MainActor
    func testRangeRowRendersAsCompactSpan() throws {
        let provider = CryptoPriceProvider(settings: CryptoPriceSettings(coins: ["PEPE"]))
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "crypto.pepe.range" })
        let pepe = CryptoTicker(coin: "PEPE", last: 0.00000415, open24h: 0.0000045, high24h: 0.00000454, low24h: 0.0000041)
        let line = try XCTUnwrap(CryptoPriceMapper.lines(coins: ["PEPE"], results: ["PEPE": .quote(pepe)]).last)
        guard case .values(_, let values, _, _, _, _) = line else { return XCTFail("expected values") }
        var data = descriptor.sample
        data.values = values
        XCTAssertEqual(data.unboundedDetail, "0.00000410 – 0.00000454")
    }

    func testBlockingErrorOnlyWhenNoCoinAnswered() {
        XCTAssertNil(CryptoPriceMapper.blockingError(
            coins: ["BTC", "ETH"], results: ["BTC": .failed(.connectionFailed), "ETH": .unlisted]
        ))
        XCTAssertEqual(CryptoPriceMapper.blockingError(
            coins: ["BTC", "ETH"], results: ["BTC": .failed(.requestFailed(503)), "ETH": .failed(.connectionFailed)]
        ), .requestFailed(503))
    }
}

final class PriceFormattingTests: XCTestCase {
    func testPricePrecisionFollowsMagnitude() {
        XCTAssertEqual(MetricFormatter.number(66481.7, kind: .price, style: .row), "66,481.70")
        XCTAssertEqual(MetricFormatter.number(66481.7, kind: .price, style: .tray), "66,482")
        XCTAssertEqual(MetricFormatter.number(3.14159, kind: .price, style: .row), "3.1416")
        XCTAssertEqual(MetricFormatter.number(0.0000123, kind: .price, style: .tray), "0.00001230")
    }

    func testChangeIsSignedAndUnclamped() {
        XCTAssertEqual(MetricFormatter.number(2.346, kind: .change, style: .row), "+2.35%")
        XCTAssertEqual(MetricFormatter.number(-4.2433, kind: .change, style: .row), "-4.24%")
        XCTAssertEqual(MetricFormatter.number(150, kind: .change, style: .row), "+150.00%")
        XCTAssertEqual(MetricFormatter.number(0, kind: .change, style: .row), "0.00%")
    }

    func testPriceRowSplitsChangeForTinting() throws {
        var data = WidgetData(title: "BTC", icon: .providerMark("crypto"), kind: .price, used: 0, limit: nil)
        data.values = [MetricValue(number: 66481.7, kind: .price), MetricValue(number: -4.24, kind: .change)]
        let parts = try XCTUnwrap(data.priceChangeParts)
        XCTAssertEqual(parts.lead, "66,481.70")
        XCTAssertEqual(parts.change, "-4.24%")
        XCTAssertTrue(parts.isDown)
        XCTAssertEqual(data.unboundedDetail, "66,481.70 · -4.24%")
        XCTAssertEqual(data.menuBarValue, "66,482")
    }
}

@MainActor
final class CryptoPriceProviderTests: XCTestCase {
    func testRefreshFetchesEachCoinAndMapsLines() async throws {
        let http = RoutingHTTPClient { request in
            let instID = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "instId" }?.value
            let body = instID == "BTC-USDT"
                ? CryptoTickerParsingTests.tickerBody(last: "66481.7", open: "69427.9")
                : Data(#"{"code":"51001","data":[],"msg":""}"#.utf8)
            return HTTPResponse(statusCode: 200, headers: [:], body: body)
        }
        let provider = CryptoPriceProvider(
            settings: CryptoPriceSettings(coins: ["BTC", "NOPE"], apiBase: "https://okx.test"),
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(Set(http.requests.map(\.url.absoluteString)), [
            "https://okx.test/api/v5/market/ticker?instId=BTC-USDT",
            "https://okx.test/api/v5/market/ticker?instId=NOPE-USDT",
        ])
        XCTAssertEqual(snapshot.lines.map(\.label), ["BTC", "BTC 24h Range", "NOPE"])
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(provider.refreshInterval, 15)
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["crypto.btc", "crypto.btc.range", "crypto.nope", "crypto.nope.range"])
    }

    func testPartialOutageKeepsGoodRowsAndWarns() async {
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("ETH") { throw URLError(.timedOut) }
            return HTTPResponse(statusCode: 200, headers: [:],
                                body: CryptoTickerParsingTests.tickerBody(last: "1", open: "1"))
        }
        let provider = CryptoPriceProvider(settings: CryptoPriceSettings(coins: ["BTC", "ETH"]), http: http)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["BTC", "BTC 24h Range"])
        XCTAssertEqual(snapshot.warning, "Couldn't load ETH this time.")
    }

    func testTotalOutageIsATypedError() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
        let provider = CryptoPriceProvider(settings: CryptoPriceSettings(coins: ["BTC"]), http: http)
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.allSatisfy(\.isError))
        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testDefaultLayoutTucksRangesAndPinsFirstCoin() {
        let defaults = CryptoPriceProvider.defaultLayout(coins: ["BTC", "ETH"])
        XCTAssertEqual(defaults.metricIDs, ["crypto.btc", "crypto.btc.range", "crypto.eth", "crypto.eth.range"])
        XCTAssertEqual(defaults.expandedMetricIDs, ["crypto.btc.range", "crypto.eth.range"])
        XCTAssertEqual(defaults.pinnedMetricIDs, ["crypto.btc"])
    }
}
