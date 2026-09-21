import CleanerCore
import Darwin
import Foundation

/// A secret or risky setting found in the user's files. The secret itself is
/// never kept in full: `preview` shows only its first and last characters.
public struct SecretFinding: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case sshKeyWithoutPassphrase, sshKeyReadableByOthers, authorizedKeys
        case awsKey, githubToken, aiAPIKey, slackToken, googleAPIKey, stripeKey, npmToken, privateKey
        case shellDownloadAndRun, shellEncodedCommand, shellLibraryInjection, shellReverseShell
    }

    public let kind: Kind
    public let path: String
    public let line: Int?
    public let preview: String

    public var id: String { "\(kind.rawValue)|\(path)|\(line ?? 0)" }

    public var risk: PersistenceItem.Risk {
        switch kind {
        case .shellReverseShell, .shellLibraryInjection, .shellDownloadAndRun, .shellEncodedCommand: .high
        case .sshKeyReadableByOthers, .awsKey, .githubToken, .aiAPIKey, .slackToken, .stripeKey, .privateKey: .medium
        case .googleAPIKey, .npmToken, .sshKeyWithoutPassphrase: .low
        case .authorizedKeys: .low
        }
    }
}

public enum SecretScanner {
    static let tokenPatterns: [(SecretFinding.Kind, String)] = [
        (.awsKey, #"AKIA[0-9A-Z]{16}"#),
        (.githubToken, #"gh[pousr]_[A-Za-z0-9]{36,}"#),
        (.aiAPIKey, #"sk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}"#),
        (.slackToken, #"xox[abprs]-[A-Za-z0-9-]{10,}"#),
        (.googleAPIKey, #"AIza[0-9A-Za-z_-]{35}"#),
        (.stripeKey, #"sk_live_[0-9A-Za-z]{24,}"#),
        (.npmToken, #"npm_[A-Za-z0-9]{36}"#),
        (.privateKey, #"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#),
    ]

    static let shellPatterns: [(SecretFinding.Kind, String)] = [
        (.shellDownloadAndRun, #"(curl|wget)[^|;\n]*\|\s*(ba|z)?sh\b"#),
        (.shellEncodedCommand, #"base64\s+(-d|--decode|-D)[^\n]*\|\s*(ba|z)?sh\b|eval\s*\"?\$\((curl|wget)"#),
        (.shellLibraryInjection, #"DYLD_INSERT_LIBRARIES\s*="#),
        (.shellReverseShell, #"(bash\s+-i\s*>&\s*/dev/tcp/|\bnc\b[^\n]*\s-e\s|/dev/tcp/\d+\.\d+\.\d+\.\d+/\d+)"#),
    ]

    /// Names of files that commonly hold credentials.
    static func isCredentialFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env")
            || [".npmrc", ".pypirc", ".netrc", "credentials", "credentials.json", ".git-credentials", "secrets.json"]
            .contains(lower)
            || lower.hasSuffix(".pem") || lower.hasSuffix(".key")
    }

    public static func scan(home: String = NSHomeDirectory()) async -> [SecretFinding] {
        var findings = sshFindings(home: home)
        findings += shellFindings(home: home)
        findings += await credentialFileFindings(home: home)
        return findings.sorted { ($0.risk, $1.path) > ($1.risk, $0.path) }
    }

    // MARK: - SSH

    static func sshFindings(home: String) -> [SecretFinding] {
        let folder = home + "/.ssh"
        var findings: [SecretFinding] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = folder + "/" + name
            if name == "authorized_keys" {
                let keys = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                    .split(separator: "\n")
                    .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !keys.isEmpty {
                    findings.append(SecretFinding(
                        kind: .authorizedKeys,
                        path: path,
                        line: nil,
                        preview: "\(keys.count)"
                    ))
                }
                continue
            }
            guard !name.hasSuffix(".pub"), let contents = try? String(contentsOfFile: path, encoding: .utf8),
                  contents.contains("PRIVATE KEY-----")
            else { continue }
            var info = stat()
            if stat(path, &info) == 0, info.st_mode & 0o077 != 0 {
                findings.append(SecretFinding(
                    kind: .sshKeyReadableByOthers,
                    path: path,
                    line: nil,
                    preview: String(format: "%o", info.st_mode & 0o777)
                ))
            }
            if !isEncrypted(privateKey: contents) {
                findings.append(SecretFinding(kind: .sshKeyWithoutPassphrase, path: path, line: nil, preview: name))
            }
        }
        return findings
    }

    /// PEM keys say "ENCRYPTED"; OpenSSH keys name their cipher, "none" when unprotected.
    static func isEncrypted(privateKey contents: String) -> Bool {
        if contents.contains("ENCRYPTED") {
            return true
        }
        guard contents.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let body = contents.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { return true }
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic), data.count > magic.count + 4 else { return true }
        let lengthBytes = data[data.startIndex + magic.count ..< data.startIndex + magic.count + 4]
        let length = lengthBytes.reduce(0) { $0 << 8 | Int($1) }
        let nameStart = data.startIndex + magic.count + 4
        guard data.count >= magic.count + 4 + length else { return true }
        let cipher = String(decoding: data[nameStart ..< nameStart + length], as: UTF8.self)
        return cipher != "none"
    }

    // MARK: - Shell startup files

    static func shellFindings(home: String) -> [SecretFinding] {
        let files = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile"]
        var findings: [SecretFinding] = []
        for name in files {
            let path = home + "/" + name
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("#") else { continue }
                for (kind, pattern) in shellPatterns where text.range(of: pattern, options: .regularExpression) != nil {
                    findings.append(SecretFinding(
                        kind: kind,
                        path: path,
                        line: index + 1,
                        preview: String(text.prefix(120))
                    ))
                }
            }
        }
        return findings
    }

    // MARK: - Tokens in files

    static func credentialFileFindings(home: String) async -> [SecretFinding] {
        var options = ScanOptions()
        options.excludedPaths = [home + "/Library", home + "/.Trash"]
        guard let tree = try? await DiskScanner(options: options).scan(URL(filePath: home)).root else { return [] }

        var candidates: [String] = []
        var stack = [tree]
        while let node = stack.popLast() {
            for directory in node.directories
                where !["node_modules", ".git", ".venv", "venv", "Pods", ".build"].contains(directory.name)
            {
                stack.append(directory)
            }
            for file in node.files
                where file.type == .regular && file.logicalSize < 1_000_000 && isCredentialFile(file.name)
            {
                candidates.append(node.path(of: file))
            }
        }
        return candidates.flatMap(tokenFindings(in:))
    }

    static func tokenFindings(in path: String) -> [SecretFinding] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var findings: [SecretFinding] = []
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            for (kind, pattern) in tokenPatterns {
                if let range = text.range(of: pattern, options: .regularExpression) {
                    findings.append(SecretFinding(
                        kind: kind,
                        path: path,
                        line: index + 1,
                        preview: mask(String(text[range]))
                    ))
                }
            }
        }
        return findings
    }

    /// "sk-abcdef…wxyz": enough to recognize the key, useless to anyone else.
    static func mask(_ secret: String) -> String {
        guard secret.count > 12 else { return String(repeating: "•", count: secret.count) }
        return secret.prefix(6) + "…" + secret.suffix(4)
    }
}
