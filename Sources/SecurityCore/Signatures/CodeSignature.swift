import Foundation
import Security

/// Who signed a piece of code and whether the signature holds.
public struct CodeSignature: Sendable, Hashable {
    public enum Signer: Sendable, Hashable {
        /// Part of macOS.
        case apple
        case appStore
        case developerID(team: String, name: String)
        /// Signed with a development certificate (not meant for distribution).
        case development(team: String, name: String)
        /// Signed without an identity; anyone can produce such a signature.
        case adHoc
        case unsigned
        case other(name: String)
    }

    public enum Validity: Sendable, Hashable {
        case valid
        /// The code was changed after signing, or the signature is broken.
        case invalid(String)
        case notSigned
        /// The file cannot be read without administrator rights.
        case unreadable
    }

    /// How much the signature alone lets us trust the code.
    public enum Trust: Int, Sendable, Comparable {
        case trusted, caution, untrusted

        public static func < (lhs: Trust, rhs: Trust) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let signer: Signer
    public let validity: Validity
    public let identifier: String?
    public let teamID: String?
    public let isNotarized: Bool
    public let hasHardenedRuntime: Bool
    /// Entitlements that weaken the hardened runtime.
    public let riskyEntitlements: [String]

    public var trust: Trust {
        if validity == .unreadable {
            return .caution
        }
        guard validity == .valid else { return .untrusted }
        switch signer {
        case .apple, .appStore: return .trusted
        case .developerID: return isNotarized ? .trusted : .caution
        case .development, .adHoc, .other: return .caution
        case .unsigned: return .untrusted
        }
    }

    /// Code signing flags from <Security/CSCommon.h>.
    private static let adHocFlag: UInt32 = 0x0002
    private static let runtimeFlag: UInt32 = 0x10000

    static let riskyEntitlementKeys = [
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.debugger",
    ]

    /// Inspects a bundle or executable. With `deep`, every resource of a bundle is
    /// hashed too, which catches more tampering but takes long for large apps.
    public static func inspect(_ path: String, deep: Bool = false) -> CodeSignature {
        // Root-only helpers (mode 711) cannot be read, which is not the same as unsigned.
        if access(path, R_OK) != 0, FileManager.default.fileExists(atPath: path) {
            return CodeSignature(
                signer: .unsigned, validity: .unreadable, identifier: nil, teamID: nil,
                isNotarized: false, hasHardenedRuntime: false, riskyEntitlements: []
            )
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else {
            return unsigned
        }

        var flags = kSecCSCheckAllArchitectures | kSecCSStrictValidate
        if !deep {
            flags |= kSecCSDoNotValidateResources
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: flags), nil, &error)
        if status == errSecCSUnsigned {
            return unsigned
        }
        let validity: Validity = status == errSecSuccess
            ? .valid
            : .invalid(error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "OSStatus \(status)")

        var information: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let info = information as? [String: Any] ?? [:]
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let leafName = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]

        let signer: Signer = if codeFlags & adHocFlag != 0 || certificates.isEmpty {
            .adHoc
        } else if satisfies(code, "anchor apple") {
            .apple
        } else if let leafName,
                  leafName.hasPrefix("Apple Mac OS Application Signing") || leafName.hasPrefix("TestFlight")
        {
            .appStore
        } else if let leafName, leafName.hasPrefix("Developer ID Application:") {
            .developerID(team: teamID ?? "", name: organization(from: leafName))
        } else if let leafName, leafName.hasPrefix("Apple Development:") || leafName.hasPrefix("Mac Developer:") {
            .development(team: teamID ?? "", name: organization(from: leafName))
        } else {
            .other(name: leafName ?? "")
        }

        return CodeSignature(
            signer: signer,
            validity: validity,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: teamID,
            isNotarized: satisfies(code, "notarized"),
            hasHardenedRuntime: codeFlags & runtimeFlag != 0,
            riskyEntitlements: riskyEntitlementKeys.filter { (entitlements[$0] as? Bool) == true }
        )
    }

    private static let unsigned = CodeSignature(
        signer: .unsigned, validity: .notSigned, identifier: nil, teamID: nil,
        isNotarized: false, hasHardenedRuntime: false, riskyEntitlements: []
    )

    private static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            return false
        }
        // The code itself was already validated; only match the requirement against
        // the signature, or large apps would be hashed in full once more.
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// "Developer ID Application: Brave Software, Inc. (KL8N8XSYF4)" → "Brave Software, Inc."
    static func organization(from certificateName: String) -> String {
        var name = certificateName
        if let colon = name.firstIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        if let parenthesis = name.lastIndex(of: "("), name.hasSuffix(")") {
            name = String(name[..<parenthesis])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

/// Where a downloaded file came from, from its `com.apple.quarantine` attribute.
public struct QuarantineInfo: Sendable, Hashable {
    /// The app that downloaded the file, for example "Safari".
    public let agent: String
    public let date: Date?

    public static func read(_ path: String) -> QuarantineInfo? {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, "com.apple.quarantine", &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return parse(String(decoding: buffer, as: UTF8.self))
    }

    /// Format: "flags;hex-timestamp;agent;uuid".
    static func parse(_ value: String) -> QuarantineInfo? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let date = UInt64(fields[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return QuarantineInfo(agent: String(fields[2]), date: date)
    }
}
