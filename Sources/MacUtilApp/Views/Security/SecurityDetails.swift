import CoreServices
import SecurityCore
import SwiftUI

// MARK: - App permissions

struct PermissionsList: View {
    let store: SecurityStore
    @Environment(AppState.self) private var state

    var body: some View {
        if let permissions = store.permissions {
            List {
                Text(
                    "Apps you allowed to use the camera, microphone, screen, files and more. Permissions of removed or unsigned apps deserve a look."
                )
                .foregroundStyle(.secondary)
                ForEach(PermissionGrant.Service.displayOrder, id: \.self) { service in
                    let grants = permissions.filter { $0.service.group == service }
                    if !grants.isEmpty {
                        Section(service.title) {
                            ForEach(grants) { grant in
                                PermissionRow(grant: grant, store: store)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView {
                Label("Needs Full Disk Access", systemImage: "lock.shield")
            } description: {
                Text("macOS keeps app permissions in a protected database. Grant Full Disk Access to see them.")
            } actions: {
                Button("Show Me How") { state.showsPermissionsGuide = true }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    /// App name for a bundle ID, or the file name for a command-line tool.
    static func displayName(of grant: PermissionGrant) -> String {
        if grant.clientIsPath {
            return (grant.client as NSString).lastPathComponent
        }
        guard let url = appURL(grant.client) else { return grant.client }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }

    static func appURL(_ bundleID: String) -> URL? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?
            .takeRetainedValue() as? [URL]
        else {
            return nil
        }
        return urls.first
    }
}

private struct PermissionRow: View {
    let grant: PermissionGrant
    let store: SecurityStore

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: PermissionsList.displayName(of: grant))
                    if let target = grant.target {
                        Text("controls \(target)").foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: grant.client)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(grant.findings, id: \.self) { finding in
                Badge(title: finding.description, color: grant.risk >= .medium ? .red : .orange)
            }
            Spacer()
            if grant.isSystemWide || grant.clientIsPath {
                Button("Open Settings") { NSWorkspace.shared.open(grant.service.settingsURL) }
                    .help("This permission is changed in System Settings")
            } else {
                Button("Revoke") { Task { await store.resetPermission(grant) } }
                    .help("Remove the permission. The app asks again next time it needs it.")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var icon: some View {
        if !grant.clientIsPath, let url = PermissionsList.appURL(grant.client) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
        } else {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
    }
}

extension PermissionGrant.Service {
    /// Section order; related services are grouped.
    static let displayOrder: [PermissionGrant.Service] = [
        .fullDiskAccess, .screenRecording, .accessibility, .inputMonitoring, .camera, .microphone,
        .automation, .files, .photos, .contacts, .calendars, .reminders, .bluetooth, .other(""),
    ]

    /// Unknown services are shown together under "Other".
    var group: PermissionGrant.Service {
        if case .other = self {
            return .other("")
        }
        return self
    }

    var title: LocalizedStringKey {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility (control the Mac)"
        case .fullDiskAccess: "Full Disk Access"
        case .inputMonitoring: "Input Monitoring (keystrokes)"
        case .automation: "Automation (control other apps)"
        case .photos: "Photos"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .files: "Files and Folders"
        case .bluetooth: "Bluetooth"
        case .other: "Other"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .automation: "Privacy_Automation"
        case .photos: "Privacy_Photos"
        case .contacts: "Privacy_Contacts"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .files: "Privacy_FilesAndFolders"
        case .bluetooth: "Privacy_Bluetooth"
        case .other: "Privacy"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

extension PermissionGrant.Finding {
    var description: LocalizedStringKey {
        switch self {
        case .appRemoved: "App no longer installed"
        case .unsigned: "Not signed"
        }
    }
}

// MARK: - Network

struct NetworkReportView: View {
    let store: SecurityStore

    static func issueTitle(_ key: String) -> LocalizedStringKey {
        switch key {
        case "proxy": "A proxy server routes your traffic"
        case "hosts": "The hosts file redirects websites"
        default: "Certificates were trusted by hand"
        }
    }

    var body: some View {
        let report = store.network
        List {
            Section("Programs accepting connections") {
                if report.ports.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(report.ports) { port in
                    HStack(spacing: 10) {
                        RiskBadge(risk: port.risk)
                            .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: port.command).font(.headline)
                            Text(verbatim: port.executable ?? "").font(.caption).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(verbatim: "\(port.address):\(port.port)").monospaced()
                        Badge(
                            title: port.isExposed ? "Open to the network" : "Only this Mac",
                            color: port.isExposed ? .orange : .secondary
                        )
                        if let signature = port.signature {
                            TrustBadge(trust: signature.trust)
                        }
                    }
                }
            }
            Section("DNS servers") {
                Text(verbatim: report.dnsServers.isEmpty ? "—" : report.dnsServers.joined(separator: ", "))
                Text(
                    "Your router's address or a known provider (1.1.1.1, 8.8.8.8, 9.9.9.9) is normal. An unknown address can mean the DNS was changed to redirect you."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            WarningSection(
                title: "Proxy servers", items: report.proxies,
                emptyText: "No proxy is set.",
                advice: "Unless your company set this up, a proxy can read unencrypted traffic. Check Network settings → Details → Proxies."
            )
            WarningSection(
                title: "Custom hosts entries", items: report.hostsEntries,
                emptyText: "/etc/hosts has only the macOS defaults.",
                advice: "These lines send websites to other addresses. Malware uses this to block updates or fake sites."
            )
            WarningSection(
                title: "Manually trusted certificates", items: report.trustedCertificates,
                emptyText: "No certificates were trusted by hand.",
                advice: "A trusted root certificate lets its owner read your encrypted (HTTPS) traffic. Remove it in Keychain Access unless you know why it is there."
            )
        }
        .listStyle(.inset)
    }
}

private struct WarningSection: View {
    let title: LocalizedStringKey
    let items: [String]
    let emptyText: LocalizedStringKey
    let advice: LocalizedStringKey

    var body: some View {
        Section(title) {
            if items.isEmpty {
                Label(emptyText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ForEach(items, id: \.self) { item in
                    Label { Text(verbatim: item).monospaced() } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(advice).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Running programs

struct SuspiciousProcessList: View {
    let store: SecurityStore

    var body: some View {
        if store.processes.isEmpty {
            ContentUnavailableView(
                "Nothing suspicious is running",
                systemImage: "checkmark.shield",
                description: Text(
                    "Every running program outside macOS is properly signed and runs from a normal place."
                )
            )
        } else {
            List {
                Text("Running programs that are not signed, run from unusual places or whose file was deleted.")
                    .foregroundStyle(.secondary)
                ForEach(store.processes) { process in
                    HStack(alignment: .top, spacing: 12) {
                        RiskBadge(risk: process.risk)
                            .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: process.pids.count > 1 ? "\(process.name) ×\(process.pids.count)" : process
                                .name)
                                .font(.headline)
                            Text(verbatim: process.executable).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            ForEach(process.findings, id: \.self) { finding in
                                Label(finding.description, systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if FileManager.default.isReadableFile(atPath: process.executable) {
                            VirusTotalCell(path: process.executable, store: store)
                        }
                    }
                    .contextMenu {
                        Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([process.executable]) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Browser extensions

struct ExtensionsList: View {
    let store: SecurityStore

    var body: some View {
        if store.extensions.isEmpty {
            ContentUnavailableView(
                "No browser extensions found",
                systemImage: "puzzlepiece.extension",
                description: Text(
                    "Extensions of Chrome, Brave, Edge, Arc, Vivaldi, Opera and Firefox are checked. Reading them needs Full Disk Access."
                )
            )
        } else {
            List {
                Text(
                    "An extension that can read every website sees your passwords, messages and banking pages. Keep only the ones you trust."
                )
                .foregroundStyle(.secondary)
                ForEach(Array(Set(store.extensions.map(\.browser))).sorted(), id: \.self) { browser in
                    Section(browser) {
                        ForEach(store.extensions.filter { $0.browser == browser }) { item in
                            HStack(alignment: .top, spacing: 12) {
                                RiskBadge(risk: item.risk)
                                    .frame(width: 96, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(verbatim: item.name).font(.headline)
                                        if let version = item.version {
                                            Text(verbatim: version).foregroundStyle(.tertiary)
                                        }
                                    }
                                    HStack(spacing: 6) {
                                        if item.readsAllSites {
                                            Badge(title: "Reads all websites", color: .orange)
                                        }
                                        ForEach(item.sensitivePermissions, id: \.self) { permission in
                                            Badge(title: "\(permission)", color: .secondary)
                                        }
                                    }
                                }
                                Spacer()
                            }
                            .contextMenu {
                                Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([item.path]) }
                            }
                        }
                    }
                }
                Text("To remove an extension, open the browser's extensions page.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Keys and secrets

struct SecretsList: View {
    let store: SecurityStore

    var body: some View {
        if store.secrets.isEmpty {
            ContentUnavailableView(
                "No exposed keys found",
                systemImage: "key",
                description: Text(
                    "SSH keys, shell startup files and credential files in your home folder were checked."
                )
            )
        } else {
            List {
                Text("Only the first and last characters of each key are shown. MacUtil never sends them anywhere.")
                    .foregroundStyle(.secondary)
                ForEach(store.secrets) { secret in
                    HStack(alignment: .top, spacing: 12) {
                        RiskBadge(risk: secret.risk)
                            .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(secret.kind.title).font(.headline)
                            Text(verbatim: FinderActions.abbreviate(secret.path) + (secret.line.map { ":\($0)" } ?? ""))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if !secret.preview.isEmpty, secret.kind != .authorizedKeys,
                               secret.kind != .sshKeyWithoutPassphrase
                            {
                                Text(verbatim: secret.preview).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Text(secret.kind.advice).font(.callout)
                        }
                        Spacer()
                    }
                    .contextMenu {
                        Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([secret.path]) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

extension SecretFinding.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .sshKeyWithoutPassphrase: "SSH key without a passphrase"
        case .sshKeyReadableByOthers: "SSH key readable by other users"
        case .authorizedKeys: "Keys that may log in over SSH"
        case .awsKey: "AWS access key"
        case .githubToken: "GitHub token"
        case .aiAPIKey: "AI service API key"
        case .slackToken: "Slack token"
        case .googleAPIKey: "Google API key"
        case .stripeKey: "Stripe live key"
        case .npmToken: "npm token"
        case .privateKey: "Private key in a file"
        case .shellDownloadAndRun: "Shell runs a script from the internet"
        case .shellEncodedCommand: "Shell runs a hidden (encoded) command"
        case .shellLibraryInjection: "Shell injects a library into every program"
        case .shellReverseShell: "Shell opens a remote connection"
        }
    }

    var advice: LocalizedStringKey {
        switch self {
        case .sshKeyWithoutPassphrase: "Anyone who copies the file can use the key. Add a passphrase with ssh-keygen -p."
        case .sshKeyReadableByOthers: "Restrict it with chmod 600 on the file."
        case .authorizedKeys: "Whoever holds these keys can log in when Remote Login is on. Remove keys you do not recognize."
        case .shellDownloadAndRun, .shellEncodedCommand, .shellLibraryInjection, .shellReverseShell:
            "This runs every time you open Terminal. Remove the line unless you added it yourself."
        default: "Anyone who reads this file can use the key. Move it to the Keychain or a password manager and rotate it."
        }
    }
}
