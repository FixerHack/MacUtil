import CleanerCore
import CoreServices
import Foundation
import SQLite3

/// A permission an app was given in Privacy & Security, read from the TCC databases.
public struct PermissionGrant: Sendable, Identifiable, Hashable {
    public enum Service: Hashable, Sendable {
        case camera, microphone, screenRecording, accessibility, fullDiskAccess, inputMonitoring
        case automation, photos, contacts, calendars, reminders, files, bluetooth, other(String)

        init(_ raw: String) {
            self = switch raw {
            case "kTCCServiceCamera": .camera
            case "kTCCServiceMicrophone": .microphone
            case "kTCCServiceScreenCapture": .screenRecording
            case "kTCCServiceAccessibility", "kTCCServicePostEvent": .accessibility
            case "kTCCServiceSystemPolicyAllFiles": .fullDiskAccess
            case "kTCCServiceListenEvent": .inputMonitoring
            case "kTCCServiceAppleEvents": .automation
            case "kTCCServicePhotos", "kTCCServicePhotosAdd": .photos
            case "kTCCServiceAddressBook": .contacts
            case "kTCCServiceCalendar": .calendars
            case "kTCCServiceReminders": .reminders
            case "kTCCServiceBluetoothAlways": .bluetooth
            case let other where other.hasPrefix("kTCCServiceSystemPolicy"): .files
            default: .other(raw)
            }
        }

        /// Permissions that let an app watch or control the whole Mac.
        public var isPowerful: Bool {
            switch self {
            case .screenRecording, .accessibility, .fullDiskAccess, .inputMonitoring: true
            default: false
            }
        }
    }

    public enum Finding: Sendable, Hashable {
        /// The app the permission belongs to is gone.
        case appRemoved
        /// The program holding the permission is not signed.
        case unsigned
    }

    public let service: Service
    /// Bundle ID or, for command-line tools, a path.
    public let client: String
    public let clientIsPath: Bool
    /// For Automation: the app being controlled.
    public let target: String?
    public let lastModified: Date?
    /// Stored in the system-wide database (needs admin rights to reset).
    public let isSystemWide: Bool
    public let findings: [Finding]

    public var id: String { "\(service)|\(client)|\(target ?? "")|\(isSystemWide)" }

    public var risk: PersistenceItem.Risk {
        if findings.contains(.unsigned) {
            return service.isPowerful ? .high : .medium
        }
        if findings.contains(.appRemoved) {
            return .low
        }
        return .none
    }
}

public enum PrivacyPermissions {
    public enum ReadError: Error {
        /// The databases need Full Disk Access.
        case noAccess
    }

    public static func load(home: String = NSHomeDirectory()) throws(ReadError) -> [PermissionGrant] {
        let user = read(home + "/Library/Application Support/com.apple.TCC/TCC.db", systemWide: false)
        let system = read("/Library/Application Support/com.apple.TCC/TCC.db", systemWide: true)
        if user == nil, system == nil {
            throw .noAccess
        }
        return ((user ?? []) + (system ?? [])).sorted {
            ($0.risk, $1.client) > ($1.risk, $0.client)
        }
    }

    /// Allowed entries of one TCC database, or nil if it cannot be opened.
    static func read(_ path: String, systemWide: Bool) -> [PermissionGrant]? {
        var database: OpaquePointer?
        // immutable=1 reads without taking locks tccd holds.
        let uri = "file:\(path)?immutable=1"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT service, client, client_type, IFNULL(indirect_object_identifier, ''), last_modified FROM access WHERE auth_value >= 2"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var grants: [PermissionGrant] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let client = text(1)
            let isPath = sqlite3_column_int(statement, 2) == 1
            let target = text(3)
            let modified = sqlite3_column_int64(statement, 4)
            grants.append(PermissionGrant(
                service: .init(text(0)),
                client: client,
                clientIsPath: isPath,
                target: target.isEmpty || target == "UNUSED" ? nil : target,
                lastModified: modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil,
                isSystemWide: systemWide,
                findings: findings(client: client, isPath: isPath)
            ))
        }
        return grants
    }

    static func findings(client: String, isPath: Bool) -> [PermissionGrant.Finding] {
        if isPath {
            guard FileManager.default.fileExists(atPath: client) else { return [.appRemoved] }
            let signature = CodeSignature.inspect(client)
            return signature.validity == .notSigned || signature.signer == .unsigned ? [.unsigned] : []
        }
        if client.hasPrefix("com.apple.") {
            return []
        }
        let urls = LSCopyApplicationURLsForBundleIdentifier(client as CFString, nil)?.takeRetainedValue()
        return urls.map { CFArrayGetCount($0) > 0 } == true ? [] : [.appRemoved]
    }

    /// Removes the app's permission for this service from the user database.
    /// System-wide entries need administrator rights and are changed in System Settings.
    public static func reset(_ grant: PermissionGrant) async -> Bool {
        guard !grant.isSystemWide, !grant.clientIsPath, let service = serviceName(grant.service) else { return false }
        return await Command.run("/usr/bin/tccutil", ["reset", service, grant.client])?.status == 0
    }

    private static func serviceName(_ service: PermissionGrant.Service) -> String? {
        switch service {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .automation: "AppleEvents"
        case .photos: "Photos"
        case .contacts: "AddressBook"
        case .calendars: "Calendar"
        case .reminders: "Reminders"
        case .bluetooth: "BluetoothAlways"
        case .screenRecording: "ScreenCapture"
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "SystemPolicyAllFiles"
        case .inputMonitoring: "ListenEvent"
        case .files: nil
        case let .other(raw): raw.replacingOccurrences(of: "kTCCService", with: "")
        }
    }
}
