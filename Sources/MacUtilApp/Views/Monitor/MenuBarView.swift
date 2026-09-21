import CleanerCore
import SwiftUI

/// The menu bar icon: a sparkle and the CPU load.
struct MenuBarLabel: View {
    let monitor: MenuBarMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text(verbatim: "\(Int((monitor.sample.cpu * 100).rounded()))%")
                .monospacedDigit()
        }
        .onAppear { monitor.start() }
    }
}

struct MenuBarView: View {
    let monitor: MenuBarMonitor
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sample = monitor.sample
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(verbatim: "MacUtil").font(.headline)
                Spacer()
            }

            MeterRow(title: "CPU", symbol: "cpu", fraction: sample.cpu, detail: "\(Int((sample.cpu * 100).rounded()))%")
            if let memory = sample.memory {
                MeterRow(
                    title: "Memory", symbol: "memorychip", fraction: memory.usedFraction,
                    detail: "\(memory.used.formatted(.byteCount(style: .memory))) / \(memory.total.formatted(.byteCount(style: .memory)))"
                )
            }
            if let disk = sample.disk {
                MeterRow(
                    title: "Disk", symbol: "internaldrive", fraction: disk.usedFraction,
                    detail: "\(disk.availableCapacity.formatted(.byteCount(style: .file))) free"
                )
            }
            HStack {
                Label("Network", systemImage: "network")
                Spacer()
                Text(
                    verbatim: "↓ \(sample.download.formatted(.byteCount(style: .binary)))/s  ↑ \(sample.upload.formatted(.byteCount(style: .binary)))/s"
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            if let battery = sample.battery {
                HStack {
                    Label("Battery", systemImage: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    Spacer()
                    Text(verbatim: "\(battery.percent)%").monospacedDigit().foregroundStyle(.secondary)
                    if battery.isPluggedIn {
                        Image(systemName: "powerplug").foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open MacUtil") { open(.dashboard) }
                Spacer()
                Button("Smart Scan") {
                    open(.dashboard)
                    Task { await state.smartScan.run(state) }
                }
                .prominentButton()
            }
            Button("Quit MacUtil") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func open(_ module: Module) {
        state.selection = module
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MeterRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let fraction: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(verbatim: detail).monospacedDigit().foregroundStyle(.secondary)
            }
            Gauge(value: min(max(fraction, 0), 1)) {}
                .gaugeStyle(.linearCapacity)
                .tint(fraction > 0.85 ? .orange : .accentColor)
        }
    }
}
