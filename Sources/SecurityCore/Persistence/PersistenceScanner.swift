import CleanerCore
import Foundation

/// Something that starts automatically: a launch agent or daemon, a cron job or a
/// kernel extension. Malware almost always hides in one of these places.
public struct PersistenceItem: Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case userAgent, agent, daemon, cronJob, kernelExtension
    }

    public enum Risk: Int, Sendable, Comparable {
        case none, low, medium, high

        public static func < (lhs: Risk, rhs: Risk) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum Finding: Sendable, Hashable {
        case unsigned, invalidSignature, adHocSigned, notNotarized
        case missingExecutable
        /// The program cannot be read without administrator rights.
        case cannotInspect
        /// Runs from a temporary or shared folder.
        case suspiciousLocation(String)
        /// Runs from a hidden folder.
        case hiddenLocation(String)
        case runsScript(String)
    }

    public let id: String
    public let kind: Kind
    public let label: String
    /// The launchd plist, crontab or kext bundle.
    public let location: String?
    /// The program that runs; for scripts, the interpreter's script file when known.
    public let executable: String?
    public let arguments: [String]
    public let isEnabled: Bool
    public let signature: CodeSignature?
    public let findings: [Finding]

    public var risk: Risk {
        findings.map(Self.risk(of:)).max() ?? .none
    }

    static func risk(of finding: Finding) -> Risk {
        switch finding {
        case .unsigned, .invalidSignature, .suspiciousLocation: .high
        case .adHocSigned, .runsScript, .hiddenLocation: .medium
        case .notNotarized: .low
        case .missingExecutable, .cannotInspect: .low
        }
    }
}

public struct PersistenceScanner: Sendable {
    public var userAgents: String
    public var agents = "/Library/LaunchAgents"
    public var daemons = "/Library/LaunchDaemons"
    public var kernelExtensions = "/Library/Extensions"
    public var includesCron = true

    public init(home: String = NSHomeDirectory()) {
        userAgents = home + "/Library/LaunchAgents"
    }

    public func scan() async -> [PersistenceItem] {
        async let userDisabled = Command.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
        async let systemDisabled = Command.run("/bin/launchctl", ["print-disabled", "system"])
        let disabled = await SystemSecurityScanner.parseDisabledServices(
            (userDisabled?.text ?? "") + "\n" + (systemDisabled?.text ?? "")
        ).filter { !$0.value }.map(\.key)
        let disabledLabels = Set(disabled)

        var items: [PersistenceItem] = []
        for (folder, kind) in [(userAgents, PersistenceItem.Kind.userAgent), (agents, .agent), (daemons, .daemon)] {
            items += launchItems(in: folder, kind: kind, disabledLabels: disabledLabels)
        }
        items += kernelExtensionItems()
        if includesCron, let crontab = await Command.run("/usr/bin/crontab", ["-l"]), crontab.status == 0 {
            items += cronItems(crontab.text)
        }
        // Riskiest first, then alphabetically.
        return items.sorted { ($0.risk, $1.label) > ($1.risk, $0.label) }
    }

    // MARK: - launchd

    func launchItems(in folder: String, kind: PersistenceItem.Kind, disabledLabels: Set<String>) -> [PersistenceItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            let path = folder + "/" + name
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
            let label = plist["Label"] as? String ?? (name as NSString).deletingPathExtension
            let arguments = plist["ProgramArguments"] as? [String] ?? []
            let program = plist["Program"] as? String ?? arguments.first
            let isEnabled = (plist["Disabled"] as? Bool) != true && !disabledLabels.contains(label)
            return makeItem(
                id: path, kind: kind, label: label, location: path,
                program: program, arguments: Array(arguments.dropFirst()), isEnabled: isEnabled
            )
        }
    }

    // MARK: - Kernel extensions

    func kernelExtensionItems() -> [PersistenceItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: kernelExtensions)) ?? []
        return names.filter { $0.hasSuffix(".kext") }.sorted().map { name in
            let path = kernelExtensions + "/" + name
            let signature = CodeSignature.inspect(path)
            return PersistenceItem(
                id: path, kind: .kernelExtension, label: (name as NSString).deletingPathExtension,
                location: path, executable: path, arguments: [], isEnabled: true,
                signature: signature, findings: Self.signatureFindings(signature)
            )
        }
    }

    // MARK: - cron

    func cronItems(_ crontab: String) -> [PersistenceItem] {
        crontab.split(separator: "\n").enumerated().compactMap { index, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            // Skip variable assignments such as PATH=/usr/bin.
            if let first = line.split(separator: " ").first, first.contains("="),
               first.first?.isNumber == false, first.first != "*", first.first != "@"
            {
                return nil
            }
            // Five schedule fields (or one @keyword), then the command.
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            let scheduleLength = line.hasPrefix("@") ? 1 : 5
            guard fields.count > scheduleLength else { return nil }
            let command = fields.dropFirst(scheduleLength).joined(separator: " ")
            let program = fields.dropFirst(scheduleLength).first.map(String.init)
            return makeItem(
                id: "cron:\(index)", kind: .cronJob, label: command, location: nil,
                program: program, arguments: fields.dropFirst(scheduleLength + 1).map(String.init), isEnabled: true
            )
        }
    }

    // MARK: - Assessment

    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "python", "python3", "perl", "ruby", "osascript", "node",
    ]

    func makeItem(
        id: String, kind: PersistenceItem.Kind, label: String, location: String?,
        program: String?, arguments: [String], isEnabled: Bool
    ) -> PersistenceItem {
        var findings: [PersistenceItem.Finding] = []
        var executable = program
        var signature: CodeSignature?

        if let program {
            let name = (program as NSString).lastPathComponent
            if Self.interpreters.contains(name) {
                // The interpreter is signed by Apple; what matters is the script it runs.
                let script = arguments.first { !$0.hasPrefix("-") && $0.hasPrefix("/") }
                findings.append(.runsScript(script ?? name))
                executable = script ?? program
            } else if program.hasPrefix("/") {
                if FileManager.default.fileExists(atPath: program) {
                    let checked = CodeSignature.inspect(program)
                    signature = checked
                    findings += Self.signatureFindings(checked)
                } else {
                    findings.append(.missingExecutable)
                }
            }
            if let executable, let finding = Self.locationFinding(executable) {
                findings.append(finding)
            }
        }

        return PersistenceItem(
            id: id, kind: kind, label: label, location: location, executable: executable,
            arguments: arguments, isEnabled: isEnabled, signature: signature, findings: findings
        )
    }

    static func signatureFindings(_ signature: CodeSignature) -> [PersistenceItem.Finding] {
        switch (signature.validity, signature.signer) {
        case (.unreadable, _): [.cannotInspect]
        case (.notSigned, _), (_, .unsigned): [.unsigned]
        case (.invalid, _): [.invalidSignature]
        case (_, .adHoc): [.adHocSigned]
        case (_, .developerID) where !signature.isNotarized: [.notNotarized]
        default: []
        }
    }

    /// Places legitimate software rarely runs from.
    static func locationFinding(_ path: String) -> PersistenceItem.Finding? {
        let prefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]
        if let prefix = prefixes.first(where: { path.hasPrefix($0) }) {
            return .suspiciousLocation(prefix)
        }
        // A hidden folder anywhere in the path, other than the usual tool homes.
        let allowedHidden: Set = [
            ".local", ".cargo", ".rustup", ".nvm", ".pyenv", ".rbenv", ".bun", ".deno", ".volta", ".docker",
            ".orbstack", ".cache", ".vscode", ".cursor", ".build", ".npm", ".gradle", ".m2", ".sdkman", ".codex",
            ".claude",
        ]
        let components = path.split(separator: "/").dropLast()
        if let hidden = components.first(where: { $0.hasPrefix(".") && !allowedHidden.contains(String($0)) }) {
            return .hiddenLocation(String(hidden))
        }
        return nil
    }
}
