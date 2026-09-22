/// Static facts about the MacUtil build.
public enum MacUtilInfo {
    /// Marketing version. `scripts/build-app.sh` reads it from here for `Info.plist`.
    public static let version = "0.2.0"

    public static let bundleIdentifier = "com.fixerhack.MacUtil"
    /// GitHub "owner/name", used for release checks.
    public static let repository = "FixerHack/MacUtil"
    public static let repositoryURL = "https://github.com/\(repository)"
}
