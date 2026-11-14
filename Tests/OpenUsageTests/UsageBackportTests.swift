import XCTest
@testable import OpenUsage

final class CursorBudgetBackportTests: XCTestCase {
    func testExtraUsageKeepsSpendAndRemainingInTheSelectedBudget() throws {
        let cases: [(spend: [String: Any], used: Double, limit: Double)] = [
            (["individualLimit": 10000, "individualUsed": 0, "individualRemaining": 10000,
              "pooledLimit": 50000, "pooledUsed": 12000, "pooledRemaining": 38000,
              "totalSpend": 12000, "limitType": "user"], 0, 100),
            (["pooledLimit": 50000, "pooledUsed": 12000, "pooledRemaining": 38000,
              "individualUsed": 3400, "limitType": "team"], 120, 500),
            (["individualLimit": 10000, "individualRemaining": 7500,
              "pooledUsed": 12000, "totalSpend": 12000], 25, 100),
            (["individualLimit": 5000, "individualUsed": 0,
              "individualRemaining": 4500, "totalSpend": 1200], 12, 50),
            (["individualLimit": 10000], 0, 100)
        ]
        for entry in cases {
            let mapped = try CursorUsageMapper.mapUsage(
                usage: ["enabled": true, "planUsage": ["totalPercentUsed": 10],
                        "spendLimitUsage": entry.spend],
                planName: "Team", creditGrants: nil, stripeBalanceCents: 0
            )
            guard case .progress(_, let used, let limit, _, _, _, _) = mapped.lines.first(where: { $0.label == "On-demand" }) else {
                return XCTFail("Missing Extra Usage")
            }
            XCTAssertEqual(used, entry.used)
            XCTAssertEqual(limit, entry.limit)
        }
    }

    func testEmptyHistoryWithOmittedEventListIsACompleteDay() throws {
        let page = try CursorUsageEvents.parsePage(Data(#"{"totalUsageEventsCount":0}"#.utf8))
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertEqual(page.rejectedEventCount, 0)
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertThrowsError(try CursorUsageEvents.parsePage(Data(#"{"totalUsageEventsCount":0,"usageEventsDisplay":false}"#.utf8)))
    }
}

@MainActor
final class CursorRenewalBackportTests: XCTestCase {
    func testGenericRequestFallbackPopulatesTheExistingTotalUsageWidgetAndHistory() async throws {
        let token = makeCursorJWT()
        let http = RoutingHTTPClient { request in
            let body: String
            switch request.url {
            case CursorUsageClient.usageURL:
                body = #"{"enabled":true,"planUsage":{}}"#
            case CursorUsageClient.planURL:
                body = #"{"planInfo":{"planName":"Pro"}}"#
            case CursorUsageClient.usageEventsURL:
                body = #"{"totalUsageEventsCount":0}"#
            default:
                if request.url.path == CursorUsageClient.restUsageURL.path {
                    body = #"{"gpt-4":{"numRequests":39,"maxRequestUsage":500}}"#
                } else {
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: token]), keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled },
            usageHistoryStore: CursorUsageHistoryStore(directory: directory)
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        for label in ["Total usage", "Requests"] {
            guard case .progress(_, let used, let limit, _, _, _, _) = snapshot.lines.first(where: { $0.label == label }) else {
                return XCTFail("Missing \(label)")
            }
            XCTAssertEqual(used, 39)
            XCTAssertEqual(limit, 500)
        }
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testLocalAccessJWTCanRenewWithoutASeparateRefreshToken() async throws {
        // Exercise both proactive expiry renewal and retry after the server refuses a valid JWT.
        for expiresAt in [1_799_999_999.0, 1_900_000_000.0] {
            let old = makeCursorJWT(exp: expiresAt)
            let renewed = makeCursorJWT(exp: 2_000_000_000)
            let sqlite = KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: old])
            let http = RoutingHTTPClient { request in
                switch request.url {
                case CursorUsageClient.refreshURL:
                    let body = ProviderParse.jsonObject(try XCTUnwrap(request.body))
                    XCTAssertEqual(body?["refresh_token"] as? String, old)
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"access_token\":\"\(renewed)\"}".utf8))
                case CursorUsageClient.usageURL:
                    guard request.headers["Authorization"] == "Bearer \(renewed)" else {
                        return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                    }
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"planUsage":{"totalPercentUsed":27}}"#.utf8))
                default:
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let provider = CursorProvider(
                authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain(), now: { Date(timeIntervalSince1970: 1_800_000_000) }),
                usageClient: CursorUsageClient(http: http),
                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                pricing: { TestPricing.bundled },
                usageHistoryStore: CursorUsageHistoryStore(directory: directory)
            )
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(sqlite.writtenValues[CursorAuthStore.accessTokenKey], renewed)
            XCTAssertEqual(http.requests.filter { $0.url == CursorUsageClient.refreshURL }.count, 1)
            XCTAssertEqual(http.requests.last { $0.url == CursorUsageClient.usageURL }?.headers["Authorization"], "Bearer \(renewed)")
        }
    }
}

@MainActor
final class ZAIErrorBackportTests: XCTestCase {
    func testHTTP200WithBusiness401ReportsARejectedKey() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "test-key"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"success":false,"code":401,"msg":"Unauthorized"}"#.utf8))
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }
}

final class AntigravityHostBackportTests: XCTestCase {
    func testQuotaSummaryReadsDailyBeforeCompleteButStaleProduction() async {
        let http = RoutingHTTPClient { request in
            let fraction = request.url.host == "daily-cloudcode-pa.googleapis.com" ? 0.75 : 1.0
            let buckets = ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"].map {
                ["bucketId": $0, "remainingFraction": fraction] as [String: Any]
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: ["groups": [["buckets": buckets]]]))
        }
        let client = AntigravityUsageClient(http: http)
        let result = await client.cloudCodeAllHosts(
            path: AntigravityUsageClient.quotaSummaryPath, token: "test", userAgent: "antigravity", body: [:],
            isComplete: AntigravityUsageMapper.isCompleteSummary
        )
        guard case .ok(let bodies) = result,
              let lines = AntigravityUsageMapper.parseQuotaSummaries(bodies),
              case .progress(_, let used, _, _, _, _, _) = lines.first else {
            return XCTFail("Expected a complete quota summary")
        }
        XCTAssertEqual(used, 25)
        XCTAssertEqual(http.requests.map { $0.url.host }, ["daily-cloudcode-pa.googleapis.com"])
    }

    func testProductionFillsBucketsMissingFromDaily() async {
        let http = RoutingHTTPClient { request in
            let bucket = request.url.host == "daily-cloudcode-pa.googleapis.com" ? "gemini-5h" : "gemini-weekly"
            let body = "{\"groups\":[{\"buckets\":[{\"bucketId\":\"\(bucket)\",\"remainingFraction\":0.5}]}]}"
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let result = await AntigravityUsageClient(http: http).cloudCodeAllHosts(
            path: AntigravityUsageClient.quotaSummaryPath, token: "test", userAgent: "antigravity", body: [:],
            isComplete: AntigravityUsageMapper.isCompleteSummary
        )
        guard case .ok(let bodies) = result else { return XCTFail("Expected quota summaries") }
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummaries(bodies)?.count, 2)
        XCTAssertEqual(http.requests.map { $0.url.host }, ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"])
    }
}
