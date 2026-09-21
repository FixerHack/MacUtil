import SecurityCore
import SwiftUI

extension CodeSignature.Signer {
    var title: LocalizedStringKey {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case let .developerID(_, name): "\(name)"
        case let .development(_, name): "Development build: \(name)"
        case .adHoc: "Ad-hoc signature"
        case .unsigned: "Not signed"
        case let .other(name): "\(name)"
        }
    }
}

extension CodeSignature {
    var summary: LocalizedStringKey {
        switch validity {
        case .unreadable: return "Needs administrator rights to check"
        case .invalid: return "Signature is broken: the code was changed after signing"
        case .notSigned: return "Not signed"
        case .valid: break
        }
        if case .developerID = signer {
            return isNotarized ? "Checked by Apple (notarized)" : "Not notarized by Apple"
        }
        return signer.title
    }
}

struct TrustBadge: View {
    let trust: CodeSignature.Trust

    var body: some View {
        switch trust {
        case .trusted: Badge(title: "Trusted", color: .green)
        case .caution: Badge(title: "Caution", color: .orange)
        case .untrusted: Badge(title: "Untrusted", color: .red)
        }
    }
}

struct RiskBadge: View {
    let risk: PersistenceItem.Risk

    var body: some View {
        switch risk {
        case .none: Badge(title: "OK", color: .green)
        case .low: Badge(title: "Low risk", color: .yellow)
        case .medium: Badge(title: "Medium risk", color: .orange)
        case .high: Badge(title: "High risk", color: .red)
        }
    }
}

struct Badge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
            .fixedSize()
    }
}

extension PersistenceItem.Finding {
    var description: LocalizedStringKey {
        switch self {
        case .unsigned: "The program is not signed"
        case .invalidSignature: "The signature is broken"
        case .adHocSigned: "Signed without a developer identity"
        case .notNotarized: "Not notarized by Apple"
        case .missingExecutable: "The program no longer exists (leftover of a removed app)"
        case .cannotInspect: "Needs administrator rights to check"
        case let .suspiciousLocation(folder): "Runs from \(folder), where software rarely lives"
        case let .hiddenLocation(folder): "Runs from the hidden folder \(folder)"
        case let .runsScript(script): "Runs a script: \(script)"
        }
    }
}

extension PersistenceItem.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .userAgent: "Your launch agents"
        case .agent: "Launch agents for all users"
        case .daemon: "Background services (daemons)"
        case .cronJob: "Scheduled jobs (cron)"
        case .kernelExtension: "Kernel extensions"
        }
    }
}

extension SecurityCheck.Status {
    var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass: .green
        case .warning: .orange
        case .fail: .red
        case .info: .secondary
        }
    }
}

/// VirusTotal status of one file, with check and upload actions.
struct VirusTotalCell: View {
    let path: String
    let store: SecurityStore
    @State private var confirmingUpload = false

    var body: some View {
        HStack(spacing: 6) {
            switch store.virusTotal[path] {
            case .none:
                Button("Check", systemImage: "shield.lefthalf.filled") {
                    Task { await store.checkVirusTotal(path) }
                }
                .controlSize(.small)
                .help("Look up this file's hash on VirusTotal. The file itself is not sent.")
            case .working:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .uploading:
                ProgressView().controlSize(.small)
                Text("Uploading and scanning…").foregroundStyle(.secondary)
            case let .done(.found(report)):
                Link(destination: report.permalink) {
                    if report.detections == 0 {
                        Label("Clean · 0/\(report.engines)", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(
                            "Detected · \(report.detections)/\(report.engines)",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.red)
                    }
                }
                .help("Open the full report on virustotal.com")
            case .done(.unknown):
                Text("Unknown to VirusTotal")
                    .foregroundStyle(.secondary)
                Button("Upload…") { confirmingUpload = true }
                    .controlSize(.small)
            case let .failed(message):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help(message)
                if !store.hasAPIKey {
                    SettingsLink { Text("Add API Key") }
                        .controlSize(.small)
                } else {
                    Button("Retry") { Task { await store.checkVirusTotal(path) } }
                        .controlSize(.small)
                }
            }
        }
        .font(.callout)
        .confirmationDialog("Upload this file to VirusTotal?", isPresented: $confirmingUpload) {
            Button("Upload") { Task { await store.upload(path) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The file will be scanned by about 70 antivirus engines. Uploaded files become available to VirusTotal's security partners, so never upload personal documents."
            )
        }
    }
}
