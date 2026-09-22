/// Static facts about the MacUtil build.
public enum MacUtilInfo {
    /// Marketing version. `scripts/build-app.sh` reads it from here for `Info.plist`.
    public static let version = "0.1.1"

    public static let bundleIdentifier = "com.fixerhack.MacUtil"
    public static let repositoryURL = "https://github.com/FixerHack/MacUtil"
}
