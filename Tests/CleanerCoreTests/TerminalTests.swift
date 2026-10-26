@testable import CleanerCore
import Foundation
import Testing

@Suite struct ManagedBlockTests {
    private func file(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "mc-rc-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path(percentEncoded: false)
    }

    @Test func addsItsOwnLinesAtTheEndAndLeavesTheRestAlone() throws {
        let path = try file("export PATH=/opt/bin:$PATH\nalias ll='ls -la'\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try ManagedBlock.write(["setopt AUTO_CD"], to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("export PATH=/opt/bin:$PATH\nalias ll='ls -la'"))
        #expect(text.contains(ManagedBlock.begin))
        #expect(text.contains("setopt AUTO_CD"))
        #expect(text.contains(ManagedBlock.end))
    }

    @Test func givesTheFileBackExactlyAsItWas() throws {
        let original = "export PATH=/opt/bin:$PATH\nalias ll='ls -la'\n"
        let path = try file(original)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try ManagedBlock.write(["setopt AUTO_CD", "setopt CORRECT"], to: path)
        try ManagedBlock.remove(from: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }

    @Test func replacesItsBlockRatherThanStackingThem() throws {
        let path = try file("# mine\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try ManagedBlock.write(["one"], to: path)
        try ManagedBlock.write(["two"], to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.components(separatedBy: ManagedBlock.begin).count == 2)
        #expect(!text.contains("one"))
        #expect(text.contains("two"))
    }

    @Test func readsBackOnlyWhatItWrote() throws {
        let path = try file("alias g=git\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try ManagedBlock.write(["setopt AUTO_CD", "HISTSIZE=50000"], to: path)
        #expect(ManagedBlock.read(from: path) == ["setopt AUTO_CD", "HISTSIZE=50000"])
    }

    @Test func doesNotCreateAFileJustToLeaveItEmpty() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "mc-missing-\(UUID().uuidString)").path(percentEncoded: false)
        try ManagedBlock.remove(from: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func survivesAFileThatIsNothingButTheBlock() throws {
        let path = try file("")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try ManagedBlock.write(["setopt AUTO_CD"], to: path)
        #expect(ManagedBlock.read(from: path) == ["setopt AUTO_CD"])
        try ManagedBlock.remove(from: path)
        #expect(ManagedBlock.read(from: path).isEmpty)
    }
}

@Suite struct TerminalSettingsTests {
    @Test func everySettingIsDescribedAndUnique() {
        let ids = TerminalSettings.all.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(TerminalSettings.all.allSatisfy { !$0.id.isEmpty })
        // Only the "no login message" one works by the file existing rather than by its lines.
        #expect(TerminalSettings.all.allSatisfy { !$0.lines.isEmpty || $0.place == .login })
    }

    @Test func gitSettingsCarryAKeyAndAValue() {
        for option in TerminalSettings.all where option.place == .git {
            #expect(option.lines.count == 2)
            #expect(option.lines[0].contains("."))
        }
    }

    @Test func sshSettingsAllSitUnderOneCatchAll() {
        let ssh = TerminalSettings.all.filter { $0.place == .ssh }
        #expect(!ssh.isEmpty)
        #expect(ssh.allSatisfy { $0.lines.first == "Host *" })
    }

    @Test func writesEverySshSettingUnderASingleHostLine() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "mc-ssh-\(UUID().uuidString)").path(percentEncoded: false)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try TerminalSettings.writeBlock(
            for: .ssh, wanted: ["ssh.keychain", "ssh.keepAlive"], to: path
        )
        let lines = ManagedBlock.read(from: path)
        #expect(lines.filter { $0 == "Host *" }.count == 1)
        #expect(lines.first == "Host *")
        #expect(lines.contains("  UseKeychain yes"))
        #expect(lines.contains("  ServerAliveInterval 60"))
    }

    @Test func choosingNothingLeavesNoBlockBehind() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "mc-zsh-\(UUID().uuidString)").path(percentEncoded: false)
        try "alias g=git\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try TerminalSettings.writeBlock(for: .shell, wanted: ["shell.autocd"], to: path)
        #expect(!ManagedBlock.read(from: path).isEmpty)

        try TerminalSettings.writeBlock(for: .shell, wanted: [], to: path)
        #expect(ManagedBlock.read(from: path).isEmpty)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "alias g=git\n")
    }
}
