import Foundation

/// Single source of truth for the default background refresh cadence.
///
/// The periodic refresh loop and the snapshot-cache TTL both read the cadence through here so they can
/// never disagree: the cache treats a snapshot as fresh for exactly one refresh interval, and the loop
/// re-fetches when that window elapses. A provider may declare a shorter `ProviderRuntime.refreshInterval`
/// (market prices); the loop then wakes at the shortest enabled interval and every other provider stays a
/// cache hit until its own window elapses.
enum RefreshSetting {
    static let defaultMinutes = 5
    static let interval = TimeInterval(defaultMinutes * 60)
    /// Floor for any provider's interval, so a misconfigured plugin can't spin the loop.
    static let minimumInterval: TimeInterval = 10
}
