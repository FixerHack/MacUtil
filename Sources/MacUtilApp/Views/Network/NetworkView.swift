import CleanerCore
import SwiftUI

/// Every network interface this Mac has, and what each one carries.
struct NetworkView: View {
    let store: NetworkStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.hasLoaded {
                BusyView(title: "Reading the network…")
            } else {
                header
                Divider()
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Network Adapters")
        .task { await store.watch() }
    }

    private var header: some View {
        HStack(spacing: 20) {
            summary(
                title: "Carrying traffic",
                value: store.snapshot.adapters.first { $0.carriesDefaultRoute }?.name ?? "—",
                symbol: "arrow.left.arrow.right"
            )
            summary(title: "Usable", value: store.activeCount.formatted(), symbol: "antenna.radiowaves.left.and.right")
            if !store.snapshot.dnsServers.isEmpty {
                summary(
                    title: "DNS",
                    value: store.snapshot.dnsServers.prefix(2).joined(separator: ", "),
                    symbol: "list.bullet.rectangle"
                )
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func summary(title: LocalizedStringKey, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value).font(.headline).lineLimit(1)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.adapters) { adapter in
                row(adapter)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ adapter: NetworkAdapter) -> some View {
        let rate = store.rate(for: adapter)
        return HStack(spacing: 12) {
            Image(systemName: symbol(for: adapter.kind))
                .font(.title3)
                .foregroundStyle(adapter.isActive ? Color.accentColor : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: adapter.name).lineLimit(1)
                    Text(verbatim: adapter.device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if adapter.carriesDefaultRoute {
                        Text("In use")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: .capsule)
                    }
                }
                HStack(spacing: 6) {
                    Text(status(adapter))
                    if let speed = adapter.linkSpeed {
                        Text("· \(speed) Mbit/s")
                    }
                    if let address = adapter.addresses.first {
                        Text(verbatim: "· \(address)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if adapter.isActive {
                VStack(alignment: .trailing, spacing: 2) {
                    traffic(symbol: "arrow.down", bytes: rate.down)
                    traffic(symbol: "arrow.up", bytes: rate.up)
                }
            }
            if let order = adapter.order, order != .max {
                Text(verbatim: "#\(order)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(Text("Where macOS tries this one in the order of services."))
            }
        }
        .padding(.vertical, 2)
    }

    private func traffic(symbol: String, bytes: Int64) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(verbatim: "\(bytes.formatted(.byteCount(style: .file)))/s")
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func status(_ adapter: NetworkAdapter) -> LocalizedStringKey {
        if adapter.isActive { "Connected" } else if adapter.isUp { "No link" } else { "Off" }
    }

    private func symbol(for kind: NetworkAdapter.Kind) -> String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .tether: "iphone.gen3"
        case .bridge: "square.stack.3d.up"
        case .vpn: "lock.shield"
        case .loopback: "arrow.triangle.2.circlepath"
        case .other: "network"
        }
    }
}
