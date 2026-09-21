import SecurityCore
import SwiftUI

struct SystemChecksList: View {
    let checks: [SecurityCheck]

    var body: some View {
        List(checks.sorted { $0.status < $1.status }) { check in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: check.status.symbol)
                    .font(.title3)
                    .foregroundStyle(check.status.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.title).font(.headline)
                    Text(check.summary).foregroundStyle(.secondary)
                    if let advice = check.advice {
                        Text(advice).font(.callout)
                    }
                }
                Spacer()
                if check.status != .pass, let url = check.settingsURL {
                    Button("Open Settings") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }
}

struct AppsSignatureList: View {
    let store: SecurityStore
    @State private var onlyIssues = false
    @State private var selection: InstalledApp.ID?

    private var apps: [InstalledApp] {
        let apps = onlyIssues ? store.apps.filter { $0.signature.trust != .trusted } : store.apps
        return apps.sorted { ($0.signature.trust, $1.name) > ($1.signature.trust, $0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Only apps that need attention", isOn: $onlyIssues)
                Spacer()
                Text(
                    "\(store.apps.filter { $0.signature.trust != .trusted }.count) of \(store.apps.count) need attention"
                )
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            Table(apps, selection: $selection) {
                TableColumn("App") { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(verbatim: app.name)
                        if let version = app.version {
                            Text(verbatim: version).foregroundStyle(.tertiary)
                        }
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("Signature") { app in
                    HStack(spacing: 6) {
                        TrustBadge(trust: app.signature.trust)
                        Text(app.signature.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 220, ideal: 320)
                TableColumn("VirusTotal") { app in
                    VirusTotalCell(path: app.path, store: store)
                }
                .width(min: 150, ideal: 190)
            }
            .contextMenu(forSelectionType: InstalledApp.ID.self) { paths in
                if let path = paths.first {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                    }
                }
            }
        }
    }
}

struct AutostartList: View {
    let store: SecurityStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Programs that start automatically. Malware almost always hides here.")
                    .foregroundStyle(.secondary)
                Spacer()
                if let progress = store.bulkProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 120)
                    Text("\(progress.done) of \(progress.total)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Button("Check All on VirusTotal", systemImage: "shield.lefthalf.filled") {
                        Task { await store.checkAllAutostart() }
                    }
                    .disabled(!store.hasAPIKey)
                    .help(store
                        .hasAPIKey ? "Free API keys allow 4 lookups a minute, so this takes a while." :
                        "Add a VirusTotal API key in Settings first.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if store.persistence.isEmpty {
                ContentUnavailableView("Nothing starts automatically", systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(PersistenceItem.Kind.allCases, id: \.self) { kind in
                        let items = store.persistence.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section(kind.title) {
                                ForEach(items) { item in
                                    AutostartRow(item: item, store: store)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct AutostartRow: View {
    let item: PersistenceItem
    let store: SecurityStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RiskBadge(risk: item.risk)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: item.label)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.isEnabled {
                        Badge(title: "Disabled", color: .secondary)
                    }
                }
                if let executable = item.executable {
                    Text(verbatim: executable)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let signature = item.signature {
                    Text(signature.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(item.findings, id: \.self) { finding in
                    Label(finding.description, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(item.risk >= .medium ? .orange : .secondary)
                }
            }
            Spacer()
            if let executable = item.executable, FileManager.default.isReadableFile(atPath: executable) {
                VirusTotalCell(path: executable, store: store)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let location = item.location {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: location)])
                }
            }
            if let executable = item.executable {
                Button("Copy Path", systemImage: "doc.on.clipboard") { FinderActions.copy([executable]) }
            }
        }
    }
}
