import XCTest
@testable import OpenUsage

/// Covers per-provider refresh cadence: a fast provider (market prices) refetches on its own short
/// interval while default-cadence providers stay cache hits, the loop sleeps for the shortest enabled
/// interval, and the footer countdown only moves when a default-cadence provider actually fetched.
@MainActor
final class PerProviderRefreshIntervalTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    func testFastProviderRefetchesWhileDefaultProviderStaysCached() async {
        let fixture = makeFixture()

        await fixture.store.refreshAll()
        XCTAssertEqual(fixture.fast.refreshCount, 1)
        XCTAssertEqual(fixture.slow.refreshCount, 1)

        clock.addTimeInterval(20)
        await fixture.store.refreshAll()
        XCTAssertEqual(fixture.fast.refreshCount, 2, "past its 15s interval, the fast provider refetches")
        XCTAssertEqual(fixture.slow.refreshCount, 1, "the default-cadence provider is still a cache hit")

        clock.addTimeInterval(RefreshSetting.interval)
        await fixture.store.refreshAll()
        XCTAssertEqual(fixture.fast.refreshCount, 3)
        XCTAssertEqual(fixture.slow.refreshCount, 2)
    }

    func testFooterCountdownOnlyMovesForDefaultCadenceFetches() async throws {
        let fixture = makeFixture()
        await fixture.store.refreshAll()
        let firstStamp = try XCTUnwrap(fixture.store.lastRefreshAt)

        clock.addTimeInterval(20)
        await fixture.store.refreshAll()
        XCTAssertEqual(fixture.store.lastRefreshAt, firstStamp, "a fast-only pass must not reset the countdown")

        await fixture.store.refreshAll(force: true)
        XCTAssertNotEqual(fixture.store.lastRefreshAt, firstStamp, "a forced pass always restarts it")
    }

    func testLoopWaitFollowsShortestEnabledInterval() {
        var enabled: Set<String> = ["fast", "slow"]
        let fixture = makeFixture(isEnabled: { enabled.contains($0) })
        XCTAssertEqual(fixture.store.nextRefreshWait(), 15)

        enabled = ["slow"]
        XCTAssertEqual(fixture.store.nextRefreshWait(), RefreshSetting.interval)

        enabled = []
        XCTAssertEqual(fixture.store.nextRefreshWait(), RefreshSetting.interval)
    }

    func testIntervalsAreClampedAndStalenessFollowsTheProvider() {
        let tooFast = IntervalRuntime(id: "tooFast", interval: 1, clock: { [unowned self] in clock })
        let tooSlow = IntervalRuntime(id: "tooSlow", interval: 99_999, clock: { [unowned self] in clock })
        let store = makeStore(runtimes: [tooFast, tooSlow])

        XCTAssertEqual(store.refreshInterval(for: "tooFast"), RefreshSetting.minimumInterval)
        XCTAssertEqual(store.refreshInterval(for: "tooSlow"), RefreshSetting.interval)
        XCTAssertEqual(store.stalenessThreshold(for: "tooFast"), 60)
        XCTAssertEqual(store.stalenessThreshold(for: "tooSlow"), RefreshSetting.interval * 2)
    }

    // MARK: - Helpers

    private struct Fixture {
        let store: WidgetDataStore
        let fast: IntervalRuntime
        let slow: IntervalRuntime
    }

    private func makeFixture(isEnabled: @escaping @MainActor (String) -> Bool = { _ in true }) -> Fixture {
        let fast = IntervalRuntime(id: "fast", interval: 15, clock: { [unowned self] in clock })
        let slow = IntervalRuntime(id: "slow", interval: nil, clock: { [unowned self] in clock })
        return Fixture(store: makeStore(runtimes: [fast, slow], isEnabled: isEnabled), fast: fast, slow: slow)
    }

    private func makeStore(
        runtimes: [IntervalRuntime],
        isEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) -> WidgetDataStore {
        let suite = "OpenUsageTests.PerProviderRefreshInterval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { [unowned self] in clock })
        return WidgetDataStore(
            registry: WidgetRegistry(
                providers: runtimes.map(\.provider),
                descriptors: runtimes.flatMap(\.widgetDescriptors)
            ),
            providers: runtimes,
            cache: cache,
            defaults: defaults,
            isProviderEnabled: isEnabled,
            now: { [unowned self] in clock }
        )
    }
}

/// A runtime with an optional custom interval whose snapshots are stamped with the test clock, so the
/// cache's age check sees the simulated time.
@MainActor
private final class IntervalRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let interval: TimeInterval?
    private let clock: () -> Date
    var refreshCount = 0

    init(id: String, interval: TimeInterval?, clock: @escaping () -> Date) {
        provider = Provider(id: id, displayName: id, icon: .providerMark("cursor"))
        widgetDescriptors = [WidgetDescriptor(
            id: "\(id).alpha",
            providerID: id,
            metricLabel: "Alpha",
            sample: WidgetData(title: "Alpha", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )]
        self.interval = interval
        self.clock = clock
    }

    var refreshInterval: TimeInterval { interval ?? RefreshSetting.interval }

    func refresh() async -> ProviderSnapshot {
        refreshCount += 1
        return ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: Double(refreshCount), limit: 100, format: .percent)],
            refreshedAt: clock()
        )
    }

    func hasLocalCredentials() async -> Bool { true }
}
