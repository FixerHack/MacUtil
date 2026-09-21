import SecurityCore
import SwiftUI
import UniformTypeIdentifiers

struct SecurityView: View {
    enum Section: Hashable, CaseIterable {
        case overview, system, apps, autostart, permissions, network, processes, extensions, secrets

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .system: "Settings"
            case .apps: "Apps"
            case .autostart: "Autostart"
            case .permissions: "App Permissions"
            case .network: "Network"
            case .processes: "Running Programs"
            case .extensions: "Browser Extensions"
            case .secrets: "Keys and Secrets"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.67percent"
            case .system: "gearshape"
            case .apps: "app.badge.checkmark"
            case .autostart: "power"
            case .permissions: "hand.raised"
            case .network: "network"
            case .processes: "cpu"
            case .extensions: "puzzlepiece.extension"
            case .secrets: "key"
            }
        }
    }

    let store: SecurityStore
    @Environment(AppState.self) private var state
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
                        .prominentButton()
                        .controlSize(.large)
                }
            case .scanning:
                BusyView(title: "Analyzing security…")
            case .ready:
                HStack(spacing: 0) {
                    List(Section.allCases, id: \.self, selection: $section) { item in
                        HStack {
                            Label(item.title, systemImage: item.symbol)
                            Spacer()
                            if let count = attentionCount(item), count > 0 {
                                Text(verbatim: "\(count)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .background(.orange.opacity(0.2), in: .capsule)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .tag(item)
                    }
                    .listStyle(.sidebar)
                    .frame(width: 220)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Security Analyzer")
        #if DEBUG
            .onChange(of: state.securitySection) { _, name in
                if let match = Section.allCases.first(where: { name == "\($0)" }) {
                    section = match
                }
            }
        #endif
            .toolbar {
                ToolbarItem {
                    Button("Rescan", systemImage: "arrow.clockwise") {
                        Task { await store.scan() }
                    }
                    .disabled(store.phase == .scanning)
                }
            }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .overview: SecurityOverview(store: store, section: $section)
        case .system: SystemChecksList(checks: store.checks)
        case .apps: AppsSignatureList(store: store)
        case .autostart: AutostartList(store: store)
        case .permissions: PermissionsList(store: store)
        case .network: NetworkReportView(store: store)
        case .processes: SuspiciousProcessList(store: store)
        case .extensions: ExtensionsList(store: store)
        case .secrets: SecretsList(store: store)
        }
    }

    /// Items worth a look in each section, shown as a badge.
    private func attentionCount(_ section: Section) -> Int? {
        switch section {
        case .overview: nil
        case .system: store.checks.filter { $0.status == .fail || $0.status == .warning }.count
        case .apps: store.apps.filter { $0.signature.trust == .untrusted }.count
        case .autostart: store.persistence.filter { $0.risk >= .medium }.count
        case .permissions: (store.permissions ?? []).filter { $0.risk >= .medium }.count
        case .network:
            store.network.ports.filter { $0.risk >= .medium }.count + store.network.proxies.count
                + store.network.hostsEntries.count + store.network.trustedCertificates.count
        case .processes: store.processes.filter { $0.risk >= .medium }.count
        case .extensions: store.extensions.filter { $0.risk >= .medium }.count
        case .secrets: store.secrets.filter { $0.risk >= .medium }.count
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
                case let .permission(grant):
                    Text(verbatim: PermissionsList.displayName(of: grant)).font(.headline)
                    Text(grant.service.title).foregroundStyle(.secondary)
                    ForEach(grant.findings, id: \.self) { Text($0.description).font(.callout) }
                case let .port(port):
                    Text(verbatim: "\(port.command) · \(port.address):\(port.port)").font(.headline)
                    Text("Accepts connections from the network").foregroundStyle(.secondary)
                case let .process(process):
                    Text(verbatim: process.name).font(.headline)
                    ForEach(process.findings, id: \.self) { Text($0.description).foregroundStyle(.secondary) }
                case let .browserExtension(item):
                    Text(verbatim: "\(item.name) · \(item.browser)").font(.headline)
                    Text("Can read every website and use sensitive browser features").foregroundStyle(.secondary)
                case let .secret(secret):
                    Text(secret.kind.title).font(.headline)
                    Text(verbatim: FinderActions.abbreviate(secret.path)).foregroundStyle(.secondary)
                case let .network(title, details):
                    Text(NetworkReportView.issueTitle(title)).font(.headline)
                    Text(verbatim: details.prefix(3).joined(separator: ", ")).foregroundStyle(.secondary)
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
            case .permission:
                Button("Show") { section = .permissions }
            case .port, .network:
                Button("Show") { section = .network }
            case .process:
                Button("Show") { section = .processes }
            case .browserExtension:
                Button("Show") { section = .extensions }
            case .secret:
                Button("Show") { section = .secrets }
            }
        }
    }
}

/// Drop any file or app to see its signature, origin and VirusTotal verdict.
private struct FileDropChecker: View {
    let store: SecurityStore
    @State private var path: String?
    /// Nil while checking; `.some(nil)` for documents, where signing does not apply.
    @State private var signature: CodeSignature??
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
                        if let signature {
                            HStack(spacing: 6) {
                                TrustBadge(trust: signature.trust)
                                Text(signature.summary).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("A document: code signing does not apply to it.")
                                .foregroundStyle(.secondary)
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
                signature = await Task.detached {
                    CodeSignature.appliesTo(droppedPath) ? CodeSignature.inspect(droppedPath) : nil
                }.value
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
