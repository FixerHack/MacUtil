import Foundation

/// What an app is built on, when that is something other than plain AppKit or SwiftUI.
///
/// Worth knowing for two reasons. An Electron app carries a whole copy of Chromium, so it is
/// large and, once its Electron is old, carries Chromium's old security holes with it. And
/// the others (Catalyst, iPhone apps) explain why something looks or behaves unlike a Mac app.
public struct AppRuntime: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case electron, tauri, flutter, catalyst, iOS
    }

    public let kind: Kind
    /// The engine's own version, where the app carries it (Electron does).
    public let version: String?

    public init(kind: Kind, version: String? = nil) {
        self.kind = kind
        self.version = version
    }

    public var majorVersion: Int? {
        version?.split(separator: ".").first.flatMap { Int($0) }
    }

    /// An Electron too old to be getting Chromium's security fixes any more.
    public func isOutdated(on date: Date = .now) -> Bool {
        guard kind == .electron, let major = majorVersion else { return false }
        return major < ElectronReleases.oldestSupported(on: date)
    }
}

/// When Electron versions come out, worked out rather than looked up.
///
/// Nothing here goes online. Electron has shipped a major version about every eight weeks
/// since version 15, and supports the latest three, so the date says roughly where it is.
/// One release of slack keeps an app that is merely a little behind from being called out.
public enum ElectronReleases {
    /// Electron 38 came out on 2 September 2025.
    static let anchor = (major: 38, date: Date(timeIntervalSince1970: 1_756_771_200))
    static let cadence: TimeInterval = 56 * 86400

    public static func estimatedLatest(on date: Date) -> Int {
        anchor.major + max(0, Int(date.timeIntervalSince(anchor.date) / cadence))
    }

    /// The oldest major version that may still be supported: three are, plus one of slack.
    public static func oldestSupported(on date: Date) -> Int {
        estimatedLatest(on: date) - 3
    }

    /// How many majors an app is behind the newest.
    public static func releasesBehind(_ major: Int, on date: Date = .now) -> Int {
        max(0, estimatedLatest(on: date) - major)
    }
}

public enum AppRuntimeDetector {
    /// What the app at this path is built on, or nil for a plain Mac app — or one built on
    /// something this does not recognise, which is not the same thing.
    public static func detect(_ bundlePath: String) -> AppRuntime? {
        let fileManager = FileManager.default
        func exists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: bundlePath + "/" + relative)
        }

        // An iPhone or iPad app installed on a Mac sits inside a wrapper.
        if exists("WrappedBundle") || exists("Wrapper") {
            return AppRuntime(kind: .iOS)
        }
        let electron = "Contents/Frameworks/Electron Framework.framework"
        if exists(electron) {
            let info = NSDictionary(contentsOfFile: bundlePath + "/" + electron + "/Resources/Info.plist")
            return AppRuntime(kind: .electron, version: info?["CFBundleVersion"] as? String)
        }
        if exists("Contents/Frameworks/FlutterMacOS.framework") {
            return AppRuntime(kind: .flutter)
        }

        guard let executable = Bundle(path: bundlePath)?.executablePath,
              let info = MachOLoadInfo.read(executable)
        else { return nil }
        if info.platform == MachOLoadInfo.macCatalyst {
            return AppRuntime(kind: .catalyst)
        }
        // Tauri draws with the system WebKit and leaves its name in the binary. Plenty of
        // native apps link WebKit too, so the name is what decides it.
        if info.dylibs.contains(where: { $0.contains("/WebKit.framework/") }),
           contains(executable, marker: Data("tauri".utf8))
        {
            return AppRuntime(kind: .tauri)
        }
        return nil
    }

    /// Whether a file holds these bytes. Mapped rather than read, and skipped above a size
    /// where looking would cost more than the answer is worth.
    static func contains(_ path: String, marker: Data, limit: Int = 256 * 1024 * 1024) -> Bool {
        let url = URL(filePath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else { return false }
        return data.range(of: marker) != nil
    }
}

/// The two things the load commands of an executable say that matter here: the platform it
/// was built for, and the libraries it links.
struct MachOLoadInfo: Equatable {
    static let macCatalyst: UInt32 = 6

    var platform: UInt32?
    var dylibs: [String] = []

    static let buildVersion: UInt32 = 0x32
    static let loadDylib: UInt32 = 0xC
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let reexportDylib: UInt32 = 0x8000_001F

    static func read(_ path: String) -> MachOLoadInfo? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: 4096), start.count >= 32 else { return nil }

        // A universal binary: read the slice for this Mac, or failing that the first one.
        var offset: UInt64 = 0
        let fatMagic = be32(start, 0)
        if fatMagic == 0xCAFE_BABE || fatMagic == 0xCAFE_BABF {
            let is64 = fatMagic == 0xCAFE_BABF
            let count = Int(be32(start, 4))
            guard count > 0, count <= 16 else { return nil }
            let entrySize = is64 ? 32 : 20
            guard start.count >= 8 + entrySize * count else { return nil }
            var slices: [(cpu: UInt32, offset: UInt64)] = []
            for index in 0 ..< count {
                let base = 8 + index * entrySize
                let sliceOffset = is64 ? be64(start, base + 8) : UInt64(be32(start, base + 8))
                slices.append((be32(start, base), sliceOffset))
            }
            #if arch(arm64)
                let native: UInt32 = 0x0100_000C
            #else
                let native: UInt32 = 0x0100_0007
            #endif
            offset = (slices.first { $0.cpu == native } ?? slices[0]).offset
        }

        guard (try? handle.seek(toOffset: offset)) != nil,
              let header = try? handle.read(upToCount: 32), header.count == 32
        else { return nil }
        // Only 64-bit Mach-O in the byte order of the Macs that run it.
        guard le32(header, 0) == 0xFEED_FACF else { return nil }
        let commandsSize = Int(le32(header, 20))
        guard commandsSize > 0, commandsSize < 8 * 1024 * 1024,
              let commands = try? handle.read(upToCount: commandsSize), commands.count == commandsSize
        else { return nil }
        return parse(commands: commands, count: Int(le32(header, 16)))
    }

    static func parse(commands: Data, count: Int) -> MachOLoadInfo {
        var info = MachOLoadInfo()
        var position = 0
        for _ in 0 ..< count {
            guard position + 8 <= commands.count else { break }
            let command = le32(commands, position)
            let size = Int(le32(commands, position + 4))
            guard size >= 8, position + size <= commands.count else { break }
            switch command {
            case buildVersion where size >= 12:
                info.platform = le32(commands, position + 8)
            case loadDylib, loadWeakDylib, reexportDylib:
                let nameOffset = Int(le32(commands, position + 8))
                if nameOffset < size {
                    let bytes = commands[(commands.startIndex + position + nameOffset) ..< (commands.startIndex + position + size)]
                    let name = bytes.prefix { $0 != 0 }
                    info.dylibs.append(String(decoding: name, as: UTF8.self))
                }
            default:
                break
            }
            position += size
        }
        return info
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        return bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 8]
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
