import XCTest
@testable import OpenUsage

@MainActor
final class CustomizeProviderOrderingTests: XCTestCase {
    func testEnabledProvidersAppearFirstPreservingSavedOrderWithinEachGroup() {
        let defaults = makeDefaults()
        let enablement = ProviderEnablementStore(defaults: defaults)
        let store = makeStore(defaults: defaults, enablement: enablement)
        store.providerOrder = ["cursor", "codex", "claude"]

        enablement.seedEnabledProviders(["claude", "cursor"])
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["cursor", "claude", "codex"])
        XCTAssertEqual(store.customizeProviderRows.map(\.isEnabled), [true, true, false])

        enablement.seedEnabledProviders(["claude"])
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["claude", "cursor", "codex"])
        XCTAssertEqual(store.customizeProviderRows.map(\.isEnabled), [true, false, false])
    }

    func testTogglingProviderMovesItBetweenGroupsWithoutOverwritingSavedOrder() {
        let defaults = makeDefaults()
        let enablement = ProviderEnablementStore(defaults: defaults)
        let store = makeStore(defaults: defaults, enablement: enablement)
        let savedOrder = store.providerOrder
        enablement.seedEnabledProviders(["claude", "codex", "cursor"])

        enablement.setEnabled(false, for: "codex")
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["claude", "cursor", "codex"])
        XCTAssertEqual(store.providerOrder, savedOrder)

        enablement.setEnabled(true, for: "codex")
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["claude", "codex", "cursor"])
        XCTAssertEqual(store.providerOrder, savedOrder)
    }

    func testReorderingEnabledProvidersKeepsDisabledTailAndPersistsAndUndoes() {
        let defaults = makeDefaults()
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["claude", "cursor"])
        let store = makeStore(defaults: defaults, enablement: enablement)
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["claude", "cursor", "codex"])

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["cursor", "claude", "codex"])
        let reloaded = makeStore(defaults: defaults, enablement: enablement)
        XCTAssertEqual(reloaded.customizeProviderRows.map(\.id), ["cursor", "claude", "codex"])

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.customizeProviderRows.map(\.id), ["claude", "cursor", "codex"])
    }

    func testAllEnabledOrAllDisabledPreservesSavedOrder() {
        let defaults = makeDefaults()
        let enablement = ProviderEnablementStore(defaults: defaults)
        let store = makeStore(defaults: defaults, enablement: enablement)
        let savedOrder = ["cursor", "codex", "claude"]
        store.providerOrder = savedOrder

        for enabledIDs: Set<String> in [Set(savedOrder), []] {
            enablement.seedEnabledProviders(enabledIDs)
            XCTAssertEqual(store.customizeProviderRows.map(\.id), savedOrder)
        }
    }

    private func makeStore(defaults: UserDefaults, enablement: ProviderEnablementStore) -> LayoutStore {
        LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            isProviderEnabled: { enablement.isEnabled($0) }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.CustomizeProviderOrdering.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
