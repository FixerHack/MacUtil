/// Static facts about the MacCleaner build.
public enum MacCleanerInfo {
    /// Marketing version. `scripts/build-app.sh` reads it from here for `Info.plist`.
    public static let version = "0.1.0"

    public static let bundleIdentifier = "com.fixerhack.MacCleaner"
    public static let repositoryURL = "https://github.com/FixerHack/MacCleaner"
}
