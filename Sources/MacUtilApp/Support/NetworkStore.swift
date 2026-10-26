import CleanerCore
import Foundation
import Observation

/// The network interfaces of this Mac, refreshed while the screen is open.
@MainActor
@Observable
final class NetworkStore {
    /// Bytes a second, worked out between two readings of the same interface.
    struct Rate: Sendable {
        var down: Int64 = 0
        var up: Int64 = 0
    }

    private(set) var snapshot = NetworkSnapshot()
    private(set) var rates: [String: Rate] = [:]
    private(set) var hasLoaded = false

    /// Counters from the previous reading, to turn totals into speeds.
    private var previous: [String: (received: UInt64, sent: UInt64)] = [:]
    private var lastRead: ContinuousClock.Instant?

    var adapters: [NetworkAdapter] {
        snapshot.adapters
            .filter { $0.kind != .loopback }
            .sorted {
                // Whatever carries traffic first, then the order macOS would try.
                ($0.carriesDefaultRoute ? 0 : 1, $0.order ?? .max, $0.device)
                    < ($1.carriesDefaultRoute ? 0 : 1, $1.order ?? .max, $1.device)
            }
    }

    var activeCount: Int { snapshot.usable.count }

    func rate(for adapter: NetworkAdapter) -> Rate { rates[adapter.device] ?? Rate() }

    func refresh() async {
        let fresh = await NetworkAdapters.load()
        let now = ContinuousClock.now
        if let lastRead {
            let elapsed = now - lastRead
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds > 0 {
                for adapter in fresh.adapters {
                    guard let last = previous[adapter.device] else { continue }
                    // Counters only ever climb; anything else means the interface was reset.
                    let down = adapter.received >= last.received ? adapter.received - last.received : 0
                    let up = adapter.sent >= last.sent ? adapter.sent - last.sent : 0
                    rates[adapter.device] = Rate(
                        down: Int64(Double(down) / seconds), up: Int64(Double(up) / seconds)
                    )
                }
            }
        }
        previous = Dictionary(
            uniqueKeysWithValues: fresh.adapters.map { ($0.device, (received: $0.received, sent: $0.sent)) }
        )
        lastRead = now
        snapshot = fresh
        hasLoaded = true
    }

    /// Keeps the numbers moving while the screen is on display.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
