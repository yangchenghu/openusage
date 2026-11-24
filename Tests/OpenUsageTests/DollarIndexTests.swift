import XCTest
@testable import OpenUsage

/// US Dollar Index: Yahoo chart parsing, line mapping, and the provider's refresh outcomes.
final class YahooChartParsingTests: XCTestCase {
    func testParsesMetaAndComputesChangeAgainstPreviousClose() throws {
        let quote = try YahooChartClient.parse(Self.chartBody(), symbol: "DX-Y.NYB")
        XCTAssertEqual(quote.price, 103.804)
        XCTAssertEqual(quote.dayLow, 103.749)
        XCTAssertEqual(quote.dayHigh, 104.403)
        XCTAssertEqual(try XCTUnwrap(quote.changePercent), -0.4927, accuracy: 0.0001)
    }

    func testMissingPreviousCloseHasNoChange() throws {
        let quote = try YahooChartClient.parse(Self.chartBody(previousClose: "null"), symbol: "DX-Y.NYB")
        XCTAssertNil(quote.changePercent)
    }

    func testErrorBodiesAreTyped() {
        let notFound = Data(#"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found"}}}"#.utf8)
        XCTAssertThrowsError(try YahooChartClient.parse(notFound, symbol: "NOPE")) { error in
            XCTAssertEqual(error as? DollarIndexError, .apiError("Not Found"))
        }
        XCTAssertThrowsError(try YahooChartClient.parse(Data("<html>".utf8), symbol: "X")) { error in
            XCTAssertEqual(error as? DollarIndexError, .invalidResponse)
        }
        let missingField = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":1}}],"error":null}}"#.utf8)
        XCTAssertThrowsError(try YahooChartClient.parse(missingField, symbol: "X")) { error in
            XCTAssertEqual(error as? DollarIndexError, .invalidResponse)
        }
    }

    static func chartBody(previousClose: String = "104.318") -> Data {
        Data(#"{"chart":{"result":[{"meta":{"symbol":"DX-Y.NYB","regularMarketPrice":103.804,"chartPreviousClose":\#(previousClose),"regularMarketDayHigh":104.403,"regularMarketDayLow":103.749}}],"error":null}}"#.utf8)
    }
}

@MainActor
final class DollarIndexProviderTests: XCTestCase {
    func testRefreshRequestsDXYWithUserAgentAndMapsLines() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: YahooChartParsingTests.chartBody())
        }
        let provider = DollarIndexProvider(http: http)

        let snapshot = await provider.refresh()

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString,
                       "https://query1.finance.yahoo.com/v8/finance/chart/DX-Y.NYB?interval=1d&range=1d")
        XCTAssertNotNil(request.headers["User-Agent"])
        XCTAssertEqual(snapshot.lines.map(\.label), ["DXY", "DXY Day Range"])
        guard case .values(_, let values, _, _, _, _) = snapshot.lines[0] else { return XCTFail("expected values") }
        XCTAssertEqual(values.map(\.kind), [.price, .change])
        XCTAssertEqual(provider.refreshInterval, 60)
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["dxy.price", "dxy.range"])
    }

    func testRateLimitIsATypedError() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 429, headers: [:], body: Data()) }
        let snapshot = await DollarIndexProvider(http: http).refresh()
        XCTAssertTrue(snapshot.lines.allSatisfy(\.isError))
        XCTAssertEqual(snapshot.errorCategory, ErrorCategory.http(429))
    }

    func testDefaultLayoutShowsPriceAndTucksRange() {
        XCTAssertTrue(DefaultLayout.metricIDs.contains("dxy.price"))
        XCTAssertTrue(DefaultLayout.metricIDs.contains("dxy.range"))
        XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains("dxy.range"))
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("dxy.price"))
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains { $0.hasPrefix("dxy.") })
    }
}
