import Foundation

/// Reads the Mac's security settings with the same tools an administrator would
/// use. None of them needs administrator rights.
public enum SystemSecurityScanner {
    public static func run(now: Date = Date()) async -> [SecurityCheck] {
        async let sip = Command.run("/usr/bin/csrutil", ["status"])
        async let gatekeeper = Command.run("/usr/sbin/spctl", ["--status"])
        async let fileVault = Command.run("/usr/bin/fdesetup", ["status"])
        async let firewall = Command.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        async let stealth = Command.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])
        async let screenLock = Command.run("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        async let disabledServices = Command.run("/bin/launchctl", ["print-disabled", "system"])
        async let enrollment = Command.run("/usr/bin/profiles", ["status", "-type", "enrollment"])
        // The loginwindow flag can stay on after the Guest user was removed; only
        // an existing Guest record means guests can actually log in.
        async let guestRecord = Command.run("/usr/bin/dscl", [".", "-read", "/Users/Guest", "UniqueID"])

        let services = await parseDisabledServices(disabledServices?.text ?? "")
        let guestExists = await guestRecord?.status == 0
        let updates = UserDefaults(suiteName: "/Library/Preferences/com.apple.SoftwareUpdate")
        let loginWindow = UserDefaults(suiteName: "/Library/Preferences/com.apple.loginwindow")
        let sharing = UserDefaults(suiteName: "com.apple.sharingd")

        return await [
            sipCheck(sip?.text),
            gatekeeperCheck(gatekeeper?.text),
            fileVaultCheck(fileVault?.text),
            firewallCheck(firewall?.text),
            stealthCheck(stealth?.text),
            xprotectCheck(now: now),
            updatesCheck(
                securityResponses: updates?.object(forKey: "CriticalUpdateInstall") as? Bool,
                protectionData: updates?.object(forKey: "ConfigDataInstall") as? Bool
            ),
            autoLoginCheck(user: loginWindow?.string(forKey: "autoLoginUser")),
            guestCheck(enabled: (loginWindow?.bool(forKey: "GuestEnabled") ?? false) && guestExists),
            screenLockCheck(screenLock?.text),
            serviceCheck(
                id: "remoteLogin", title: "Remote Login (SSH)",
                isOn: services["com.openssh.sshd"] == true, weight: 5,
                onSummary: "Other computers can log in to this Mac over SSH.",
                advice: "Turn it off in Sharing unless you connect to this Mac remotely."
            ),
            serviceCheck(
                id: "screenSharing", title: "Screen Sharing",
                isOn: services["com.apple.screensharing"] == true, weight: 5,
                onSummary: "Other computers can see and control this screen.",
                advice: "Turn it off in Sharing unless you need it."
            ),
            serviceCheck(
                id: "fileSharing", title: "File Sharing",
                isOn: services["com.apple.smbd"] == true, weight: 3,
                onSummary: "Folders of this Mac are shared on the network.",
                advice: "Turn it off in Sharing unless other computers need your files."
            ),
            airDropCheck(mode: sharing?.string(forKey: "DiscoverableMode")),
            managementCheck(enrollment?.text),
        ]
    }

    /// Weighted share of passing checks, 0–100. Warnings count half.
    public static func score(_ checks: [SecurityCheck]) -> Int {
        let scored = checks.filter { $0.weight > 0 && $0.status != .info }
        let total = scored.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 100 }
        let earned = scored.reduce(0.0) { sum, check in
            switch check.status {
            case .pass: sum + Double(check.weight)
            case .warning: sum + Double(check.weight) / 2
            case .fail, .info: sum
            }
        }
        return Int((earned / Double(total) * 100).rounded())
    }

    // MARK: - Checks

    static func sipCheck(_ output: String?) -> SecurityCheck {
        let on = output?.contains("status: enabled") == true
        return SecurityCheck(
            id: "sip", title: "System Integrity Protection",
            status: output == nil ? .info : on ? .pass : .fail,
            summary: on ? "System files are protected from changes." :
                "Anything with administrator rights can modify macOS itself.",
            advice: "Restart into Recovery, open Terminal and run csrutil enable.",
            weight: 20
        )
    }

    static func gatekeeperCheck(_ output: String?) -> SecurityCheck {
        let on = output?.contains("assessments enabled") == true
        return SecurityCheck(
            id: "gatekeeper", title: "Gatekeeper",
            status: on ? .pass : .fail,
            summary: on ? "Only apps from the App Store and identified developers open without a warning." :
                "Apps from anywhere open without any check.",
            advice: "Choose App Store and identified developers in Privacy & Security.",
            settingsURL: SettingsPane.privacySecurity,
            weight: 15
        )
    }

    static func fileVaultCheck(_ output: String?) -> SecurityCheck {
        let on = output?.contains("FileVault is On") == true
        return SecurityCheck(
            id: "fileVault", title: "FileVault disk encryption",
            status: on ? .pass : .fail,
            summary: on ? "The disk is encrypted. A stolen Mac does not expose your files." :
                "The disk is not encrypted. Anyone with the Mac can read your files.",
            advice: "Turn on FileVault in Privacy & Security.",
            settingsURL: SettingsPane.fileVault,
            weight: 15
        )
    }

    static func firewallCheck(_ output: String?) -> SecurityCheck {
        let on = output?.contains("enabled") == true
        return SecurityCheck(
            id: "firewall", title: "Firewall",
            status: on ? .pass : .warning,
            summary: on ? "Incoming connections are filtered." : "Any app can accept connections from the network.",
            advice: "Turn on the firewall in Network settings.",
            settingsURL: SettingsPane.firewall,
            weight: 10
        )
    }

    static func stealthCheck(_ output: String?) -> SecurityCheck {
        let on = output?.contains("stealth mode is on") == true
        return SecurityCheck(
            id: "stealthMode", title: "Firewall stealth mode",
            status: on ? .pass : .info,
            summary: on ? "The Mac does not answer probing requests such as ping." :
                "The Mac answers ping and port probes. This matters mostly on public networks.",
            advice: "Turn on stealth mode in the firewall options.",
            settingsURL: SettingsPane.firewall,
            weight: 0
        )
    }

    static func xprotectCheck(now: Date) -> SecurityCheck {
        let bundle = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
        let version =
            NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
        let updated = (try? FileManager.default.attributesOfItem(atPath: bundle))?[.modificationDate] as? Date
        guard let version, let updated else {
            return SecurityCheck(
                id: "xprotect", title: "XProtect malware definitions", status: .info,
                summary: "Could not read the XProtect version.", weight: 0
            )
        }
        let days = Int(now.timeIntervalSince(updated) / 86400)
        let date = updated.formatted(date: .abbreviated, time: .omitted)
        return SecurityCheck(
            id: "xprotect", title: "XProtect malware definitions",
            status: days <= 60 ? .pass : .warning,
            summary: "Version \(version), updated \(date).",
            advice: "Definitions are over two months old. Turn on security responses in Software Update.",
            settingsURL: SettingsPane.softwareUpdate,
            weight: 10
        )
    }

    /// Both settings default to on when the keys are missing.
    static func updatesCheck(securityResponses: Bool?, protectionData: Bool?) -> SecurityCheck {
        let on = securityResponses != false && protectionData != false
        return SecurityCheck(
            id: "securityUpdates", title: "Automatic security updates",
            status: on ? .pass : .warning,
            summary: on ? "Security responses and malware definitions install automatically." :
                "Security fixes or malware definitions do not install automatically.",
            advice: "In Software Update → Automatic Updates, turn on security responses and system files.",
            settingsURL: SettingsPane.softwareUpdate,
            weight: 10
        )
    }

    static func autoLoginCheck(user: String?) -> SecurityCheck {
        let on = user?.isEmpty == false
        return SecurityCheck(
            id: "autoLogin", title: "Automatic login",
            status: on ? .fail : .pass,
            summary: on ? "The Mac starts without asking for a password." : "A password is required after startup.",
            advice: "Turn off automatic login in Users & Groups.",
            settingsURL: SettingsPane.users,
            weight: 10
        )
    }

    static func guestCheck(enabled: Bool) -> SecurityCheck {
        SecurityCheck(
            id: "guest", title: "Guest account",
            status: enabled ? .warning : .pass,
            summary: enabled ? "Anyone can log in as a guest." : "The guest account is off.",
            advice: "Turn off the guest user in Users & Groups.",
            settingsURL: SettingsPane.users,
            weight: 5
        )
    }

    /// Understands "screenLock delay is 300 seconds", "screenLock delay is immediate" and "screenLock is off".
    static func screenLockDelay(_ output: String?) -> Int?? {
        guard let output else { return nil }
        if output.contains("screenLock is off") {
            return .some(nil)
        }
        if output.contains("immediate") {
            return .some(0)
        }
        if let range = output.range(of: #"delay is (\d+) seconds"#, options: .regularExpression) {
            let digits = output[range].filter(\.isNumber)
            return .some(Int(digits))
        }
        return nil
    }

    static func screenLockCheck(_ output: String?) -> SecurityCheck {
        let delay = screenLockDelay(output)
        let status: SecurityCheck.Status
        let summary: LocalizedStringResource
        switch delay {
        case .none:
            status = .info
            summary = "Could not read the screen lock setting."
        case .some(.none):
            status = .fail
            summary = "Waking the Mac does not ask for a password."
        case let .some(.some(seconds)) where seconds <= 60:
            status = .pass
            summary = seconds == 0 ? "A password is required immediately after sleep or screen saver." : "A password is required \(seconds) seconds after sleep or screen saver."
        case let .some(.some(seconds)):
            status = .warning
            summary = "A password is required only \(seconds / 60) minutes after sleep or screen saver."
        }
        return SecurityCheck(
            id: "screenLock", title: "Password after sleep",
            status: status, summary: summary,
            advice: "In Lock Screen, require a password immediately after sleep or screen saver.",
            settingsURL: SettingsPane.lockScreen,
            weight: 5
        )
    }

    static func serviceCheck(
        id: String, title: LocalizedStringResource, isOn: Bool, weight: Int,
        onSummary: LocalizedStringResource, advice: LocalizedStringResource
    ) -> SecurityCheck {
        SecurityCheck(
            id: id, title: title,
            status: isOn ? .warning : .pass,
            summary: isOn ? onSummary : "Off.",
            advice: advice,
            settingsURL: SettingsPane.sharing,
            weight: weight
        )
    }

    static func airDropCheck(mode: String?) -> SecurityCheck {
        let everyone = mode == "Everyone"
        return SecurityCheck(
            id: "airDrop", title: "AirDrop",
            status: everyone ? .warning : .pass,
            summary: everyone ? "Anyone nearby can send you files." :
                "Only contacts can send you files, or AirDrop is off.",
            advice: "Set AirDrop to Contacts Only.",
            settingsURL: SettingsPane.airDrop,
            weight: 2
        )
    }

    static func managementCheck(_ output: String?) -> SecurityCheck {
        let managed = output?.contains("MDM enrollment: Yes") == true
        return SecurityCheck(
            id: "management", title: "Device management",
            status: .info,
            summary: managed ? "This Mac is managed by an organization, which can install apps and settings." :
                "This Mac is not managed by an organization.",
            weight: 0
        )
    }

    /// Parses `launchctl print-disabled` lines such as `"com.openssh.sshd" => enabled`.
    /// Returns label → isEnabled.
    static func parseDisabledServices(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch parts[1] {
            case "enabled", "false": result[label] = true // "disabled => false" in older macOS
            case "disabled", "true": result[label] = false
            default: continue
            }
        }
        return result
    }
}
