import CleanerCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if state.fullDiskAccess != .granted {
                    FullDiskAccessCard(status: state.fullDiskAccess)
                }

                if let disk = state.startupDisk {
                    StartupDiskCard(volume: disk)
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to MacUtil")
                    .font(.largeTitle.bold())
                Text("Clean, optimize and protect your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {} label: {
                Label("Smart Scan", systemImage: "sparkle.magnifyingglass")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(true)
            .help("Coming soon")
        }
    }
}

struct StartupDiskCard: View {
    let volume: VolumeInfo

    var body: some View {
        DashboardCard {
            HStack(spacing: 16) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Startup Disk")
                            .font(.headline)
                        Text(verbatim: volume.name)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(format(volume.availableCapacity)) available")
                            .foregroundStyle(.secondary)
                    }
                    Gauge(value: volume.usedFraction) {}
                        .gaugeStyle(.linearCapacity)
                        .tint(volume.usedFraction > 0.9 ? .red : .accentColor)
                    Text("\(format(volume.usedCapacity)) used of \(format(volume.totalCapacity))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// Shared card container for dashboard sections.
struct DashboardCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: .rect(cornerRadius: 16))
    }
}
