import Foundation

/// Where macOS saves a screenshot.
///
/// The Desktop is the default, and on a Mac that takes a lot of them it becomes the place
/// nothing else is visible. The setting exists; it just has no switch in System Settings.
public enum ScreenshotFolder {
    static let domain = "com.apple.screencapture"
    static let key = "location"

    /// The folder in use, or the Desktop when nothing has been chosen.
    public static func current() async -> String {
        guard let output = await Command.run(
            "/usr/bin/defaults", ["read", domain, key], timeout: .seconds(15)
        ), output.status == 0 else {
            return NSHomeDirectory() + "/Desktop"
        }
        let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? NSHomeDirectory() + "/Desktop" : (path as NSString).expandingTildeInPath
    }

    public static var isDefault: Bool {
        get async { await current() == NSHomeDirectory() + "/Desktop" }
    }

    /// Why a folder will not do, in words, or nil when it will.
    public static func problem(with path: String) -> LocalizedStringResource? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "That folder does not exist."
        }
        guard isDirectory.boolValue else { return "That is a file, not a folder." }
        guard FileManager.default.isWritableFile(atPath: path) else {
            return "That folder cannot be written to."
        }
        return nil
    }

    /// Points screenshots at a folder, after checking they can actually be saved there.
    ///
    /// A folder that is missing or read-only would leave screenshots failing silently, which
    /// is why this refuses rather than writing the setting and hoping.
    @discardableResult
    public static func set(_ path: String) async -> LocalizedStringResource? {
        if let problem = problem(with: path) { return problem }
        guard await Command.run(
            "/usr/bin/defaults", ["write", domain, key, path], timeout: .seconds(15)
        )?.status == 0 else {
            return "The setting could not be written."
        }
        _ = await Command.run("/usr/bin/killall", ["SystemUIServer"], timeout: .seconds(15))
        return nil
    }

    /// Back to the Desktop.
    public static func reset() async {
        _ = await Command.run("/usr/bin/defaults", ["delete", domain, key], timeout: .seconds(15))
        _ = await Command.run("/usr/bin/killall", ["SystemUIServer"], timeout: .seconds(15))
    }
}
