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

                SmartScanSection()

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
            Button {
                Task { await state.smartScan.run(state) }
            } label: {
                Label("Smart Scan", systemImage: "sparkle.magnifyingglass")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(state.smartScan.isBusy)
            .help("Looks for junk, leftovers and security problems in one go")
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

/// Results of Smart Scan: one card per area, each leading to its module.
private struct SmartScanSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.smartScan.phase {
        case .idle:
            EmptyView()
        case .scanning:
            DashboardCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for junk, leftovers and security issues…")
                }
            }
        case .cleaning:
            DashboardCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning…")
                }
            }
        case .ready, .cleaned:
            results
        }
    }

    @ViewBuilder private var results: some View {
        let junk = state.systemJunk.selectedSize + state.developerJunk.selectedSize
        let leftovers = state.leftovers.selectedSize
        VStack(alignment: .leading, spacing: 12) {
            if case let .cleaned(result) = state.smartScan.phase {
                Label(
                    "Freed \(result.freedBytes.formatted(.byteCount(style: .file))). Items are in the Trash.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.headline)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ResultCard(
                    symbol: "sparkles", color: .blue, title: "Junk",
                    value: junk.formatted(.byteCount(style: .file)), note: "Safe to remove"
                ) { state.selection = .systemJunk }
                ResultCard(
                    symbol: "shippingbox", color: .purple, title: "Leftovers",
                    value: leftovers.formatted(.byteCount(style: .file)), note: "From removed apps"
                ) { state.selection = .leftovers }
                ResultCard(
                    symbol: "trash", color: .gray, title: "Trash",
                    value: state.trash.totalSize.formatted(.byteCount(style: .file)),
                    note: "Empty to get the space back"
                ) { state.selection = .trash }
                ResultCard(
                    symbol: "checkmark.shield", color: state.security.score >= 90 ? .green : .orange, title: "Security",
                    value: "\(state.security.score)/100", note: "\(state.security.issues.count) things to look at"
                ) { state.selection = .securityAnalyzer }
            }
            if junk + leftovers > 0 {
                HStack {
                    Text("Removes only items marked safe; apps that are running are skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clean \((junk + leftovers).formatted(.byteCount(style: .file)))") {
                        Task { await state.smartScan.cleanSafeJunk(state) }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        }
    }
}

private struct ResultCard: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    let value: String
    let note: LocalizedStringKey
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(color)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.secondary)
                    Text(verbatim: value).font(.title2.bold()).monospacedDigit()
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
