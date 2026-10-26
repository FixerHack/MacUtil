import Foundation

/// One thing the shell, Git or ssh can be told to do.
public struct TerminalOption: Sendable, Identifiable, Hashable {
    public enum Place: String, Sendable, CaseIterable {
        case shell, git, ssh, login
    }

    public let id: String
    public let place: Place
    public let title: LocalizedStringResource
    public let details: LocalizedStringResource
    /// For shell and ssh: the lines this writes. For git: the key and value.
    public let lines: [String]

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Settings zsh, Git and ssh already have, in one place and switchable.
///
/// Nothing here is invented: each one is a line these tools document. What MacUtil adds is
/// that they are visible, described in words, and removable in one press — rather than
/// pasted from an answer online into a file nobody reads again.
public enum TerminalSettings {
    public static var zshrc: String {
        NSHomeDirectory() + "/.zshrc"
    }

    public static var sshConfig: String {
        NSHomeDirectory() + "/.ssh/config"
    }

    public static var hushLogin: String {
        NSHomeDirectory() + "/.hushlogin"
    }

    public static let all: [TerminalOption] = [
        TerminalOption(
            id: "shell.history",
            place: .shell,
            title: "Remember more history",
            details: "Keeps 50 000 commands instead of the few hundred zsh keeps by default.",
            lines: ["HISTSIZE=50000", "SAVEHIST=50000", "setopt HIST_EXPIRE_DUPS_FIRST"]
        ),
        TerminalOption(
            id: "shell.shareHistory",
            place: .shell,
            title: "Share history between windows",
            details: "A command typed in one Terminal window is there in the others straight away.",
            lines: ["setopt SHARE_HISTORY", "setopt INC_APPEND_HISTORY"]
        ),
        TerminalOption(
            id: "shell.noDuplicates",
            place: .shell,
            title: "Keep history free of repeats",
            details: "The same command typed again does not fill the history with copies.",
            lines: ["setopt HIST_IGNORE_ALL_DUPS", "setopt HIST_REDUCE_BLANKS"]
        ),
        TerminalOption(
            id: "shell.caseInsensitive",
            place: .shell,
            title: "Complete without minding case",
            details: "Typing \"doc\" and pressing Tab finds Documents.",
            lines: [
                "autoload -Uz compinit && compinit",
                "zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'",
            ]
        ),
        TerminalOption(
            id: "shell.autocd",
            place: .shell,
            title: "Change folder by name alone",
            details: "Typing a folder's name goes into it, without cd.",
            lines: ["setopt AUTO_CD"]
        ),
        TerminalOption(
            id: "shell.correct",
            place: .shell,
            title: "Offer a correction for typos",
            details: "A mistyped command is met with a suggestion instead of an error.",
            lines: ["setopt CORRECT"]
        ),
        TerminalOption(
            id: "login.hush",
            place: .login,
            title: "No \"Last login\" line",
            details: "Opens the Terminal on an empty prompt instead of the login message.",
            lines: []
        ),
        TerminalOption(
            id: "git.defaultBranch",
            place: .git,
            title: "Call the first branch main",
            details: "New repositories start on main rather than master.",
            lines: ["init.defaultBranch", "main"]
        ),
        TerminalOption(
            id: "git.pullRebase",
            place: .git,
            title: "Rebase when pulling",
            details: "Keeps history in a line instead of adding a merge commit for every pull.",
            lines: ["pull.rebase", "true"]
        ),
        TerminalOption(
            id: "git.autoSetupRemote",
            place: .git,
            title: "Push a new branch without arguments",
            details: "git push works on a branch that has never been pushed, with no --set-upstream.",
            lines: ["push.autoSetupRemote", "true"]
        ),
        TerminalOption(
            id: "git.pruneOnFetch",
            place: .git,
            title: "Forget branches deleted on the server",
            details: "Fetching drops the local copies of branches that no longer exist.",
            lines: ["fetch.prune", "true"]
        ),
        TerminalOption(
            id: "ssh.keychain",
            place: .ssh,
            title: "Remember key passphrases",
            details: "Adds keys to the agent and takes their passphrase from the keychain, so it is asked once.",
            lines: ["Host *", "  AddKeysToAgent yes", "  UseKeychain yes"]
        ),
        TerminalOption(
            id: "ssh.keepAlive",
            place: .ssh,
            title: "Hold connections open",
            details: "Sends a sign of life every minute so an idle session is not dropped.",
            lines: ["Host *", "  ServerAliveInterval 60", "  ServerAliveCountMax 5"]
        ),
    ]

    // MARK: - Reading

    public static func enabled() async -> Set<String> {
        var on = Set<String>()
        let shell = ManagedBlock.read(from: zshrc)
        let ssh = ManagedBlock.read(from: sshConfig)

        for option in all {
            switch option.place {
            case .shell:
                if option.lines.allSatisfy(shell.contains) { on.insert(option.id) }
            case .ssh:
                // "Host *" is shared, so only the settings under it decide.
                if option.lines.dropFirst().allSatisfy(ssh.contains) { on.insert(option.id) }
            case .login:
                if FileManager.default.fileExists(atPath: hushLogin) { on.insert(option.id) }
            case .git:
                if let key = option.lines.first, let want = option.lines.last,
                   await gitValue(key) == want { on.insert(option.id) }
            }
        }
        return on
    }

    static func gitValue(_ key: String) async -> String? {
        guard let output = await Command.run("/usr/bin/git", ["config", "--global", "--get", key]),
              output.status == 0
        else { return nil }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Writing

    /// Puts the chosen settings in place and takes the rest out.
    public static func apply(_ wanted: Set<String>) async throws {
        try writeBlock(for: .shell, wanted: wanted, to: zshrc)
        try writeBlock(for: .ssh, wanted: wanted, to: sshConfig)

        for option in all where option.place == .git {
            guard let key = option.lines.first, let value = option.lines.last else { continue }
            let arguments = wanted.contains(option.id)
                ? ["config", "--global", key, value]
                : ["config", "--global", "--unset", key]
            _ = await Command.run("/usr/bin/git", arguments)
        }

        if let hush = all.first(where: { $0.place == .login }) {
            if wanted.contains(hush.id) {
                FileManager.default.createFile(atPath: hushLogin, contents: Data())
            } else {
                try? FileManager.default.removeItem(atPath: hushLogin)
            }
        }
    }

    /// Collects the lines of every chosen setting for one file, keeping "Host *" once.
    static func writeBlock(for place: TerminalOption.Place, wanted: Set<String>, to path: String) throws {
        var lines: [String] = []
        for option in all where option.place == place && wanted.contains(option.id) {
            for line in option.lines where !lines.contains(line) {
                lines.append(line)
            }
        }
        if place == .ssh, !lines.isEmpty {
            // Everything under one catch-all, with the host line first whatever order they came in.
            lines = ["Host *"] + lines.filter { $0 != "Host *" }
        }
        try ManagedBlock.write(lines, to: path)
    }
}
