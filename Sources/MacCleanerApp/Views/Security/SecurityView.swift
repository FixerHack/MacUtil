import SecurityCore
import SwiftUI
import UniformTypeIdentifiers

struct SecurityView: View {
    enum Section: Hashable, CaseIterable {
        case overview, system, apps, autostart

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .system: "Settings"
            case .apps: "Apps"
            case .autostart: "Autostart"
            }
        }
    }

    let store: SecurityStore
    @State private var section = Section.overview

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                ContentUnavailableView {
                    Label("Security Analyzer", systemImage: "checkmark.shield")
                } description: {
                    Text(
                        "Checks macOS security settings, app signatures and everything that starts automatically. Suspicious files can be looked up on VirusTotal."
                    )
                } actions: {
                    Button("Analyze") { Task { await store.scan() } }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            case .scanning:
                BusyView(title: "Analyzing security…")
            case .ready:
                switch section {
                case .overview: SecurityOverview(store: store, section: $section)
                case .system: SystemChecksList(checks: store.checks)
                case .apps: AppsSignatureList(store: store)
                case .autostart: AutostartList(store: store)
                }
            }
        }
        .navigationTitle("Security Analyzer")
        .toolbar {
            if case .ready = store.phase {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await store.scan() }
                }
                .disabled(store.phase == .scanning)
            }
        }
    }
}

private struct SecurityOverview: View {
    let store: SecurityStore
    @Binding var section: SecurityView.Section

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 28) {
                    ScoreRing(score: store.score)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verdict)
                            .font(.title.bold())
                        Text(
                            "\(store.issues.count) things to look at · \(store.persistence.count) autostart items · \(store.apps.count) apps"
                        )
                        .foregroundStyle(.secondary)
                        if !store.hasAPIKey {
                            HStack(spacing: 6) {
                                Image(systemName: "key")
                                Text("Add a free VirusTotal API key to check files against 70 antivirus engines.")
                                SettingsLink { Text("Add Key") }
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                FileDropChecker(store: store)

                if store.issues.isEmpty {
                    Label("No problems found.", systemImage: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Needs attention")
                            .font(.title3.bold())
                        ForEach(store.issues) { issue in
                            IssueRow(issue: issue, section: $section)
                            Divider()
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var verdict: LocalizedStringKey {
        switch store.score {
        case 90...: "Your Mac is well protected"
        case 70 ..< 90: "Your Mac is mostly protected"
        default: "Your Mac needs attention"
        }
    }
}

private struct ScoreRing: View {
    let score: Int

    private var color: Color {
        score >= 90 ? .green : score >= 70 ? .orange : .red
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(verbatim: "\(score)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("of 100")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 120)
    }
}

private struct IssueRow: View {
    let issue: SecurityStore.Issue
    @Binding var section: SecurityView.Section

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RiskBadge(risk: issue.severity)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                switch issue.target {
                case let .check(check):
                    Text(check.title).font(.headline)
                    Text(check.summary).foregroundStyle(.secondary)
                    if let advice = check.advice {
                        Text(advice).font(.callout)
                    }
                case let .persistence(item):
                    Text(verbatim: item.label).font(.headline).lineLimit(1).truncationMode(.middle)
                    ForEach(item.findings, id: \.self) { finding in
                        Text(finding.description).foregroundStyle(.secondary)
                    }
                case let .app(app):
                    Text(verbatim: app.name).font(.headline)
                    Text(app.signature.summary).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch issue.target {
            case let .check(check):
                if let url = check.settingsURL {
                    Button("Open Settings") { NSWorkspace.shared.open(url) }
                }
            case .persistence:
                Button("Show") { section = .autostart }
            case .app:
                Button("Show") { section = .apps }
            }
        }
    }
}

/// Drop any file or app to see its signature, origin and VirusTotal verdict.
private struct FileDropChecker: View {
    let store: SecurityStore
    @State private var path: String?
    @State private var signature: CodeSignature?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path, let signature {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: (path as NSString).lastPathComponent).font(.headline)
                        HStack(spacing: 6) {
                            TrustBadge(trust: signature.trust)
                            Text(signature.summary).foregroundStyle(.secondary)
                        }
                        if let quarantine = QuarantineInfo.read(path) {
                            Text("Downloaded with \(quarantine.agent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VirusTotalCell(path: path, store: store)
                    Button("Clear", systemImage: "xmark") { self.path = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            } else if path != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Label(
                    "Drop an app or file here to check its signature and VirusTotal verdict",
                    systemImage: "arrow.down.doc"
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(16)
        .background(
            isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            let droppedPath = url.path(percentEncoded: false)
            path = droppedPath
            signature = nil
            Task {
                signature = await Task.detached { CodeSignature.inspect(droppedPath) }.value
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
