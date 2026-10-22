import Foundation
import LocalAuthentication

/// Lets the Terminal's `sudo` password prompt accept a fingerprint.
///
/// macOS reads `/etc/pam.d/sudo_local` before its own rules and, unlike `/etc/pam.d/sudo`,
/// leaves that file alone when the system updates. One line in it is the whole feature.
public enum SudoTouchID {
    public static let path = "/etc/pam.d/sudo_local"
    static let line = "auth       sufficient     pam_tid.so"

    /// False on a Mac without a fingerprint reader, where the setting would do nothing.
    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public static func isEnabled() -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return contains(pamTouchID: contents)
    }

    /// True when a line mentions the module and is not commented out.
    static func contains(pamTouchID contents: String) -> Bool {
        contents.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so")
        }
    }

    public static func set(_ enabled: Bool) async -> AdminRunner.Output {
        // Appending rather than writing keeps anything else already in the file, and
        // removing touches only the lines that name the module.
        let command = enabled
            ? "grep -q '^[^#]*pam_tid.so' \(path) 2>/dev/null || printf '%s\\n' '\(line)' >> \(path)"
            : "[ -f \(path) ] && /usr/bin/sed -i '' '/pam_tid.so/d' \(path) || true"
        return await AdminRunner.run(
            [command],
            prompt: String(localized: "MacUtil needs your password to change how sudo asks for one.")
        )
    }
}
