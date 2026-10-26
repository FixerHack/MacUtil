import Foundation

/// An app that carries machine code for an architecture this Mac never runs.
public struct SlimmableApp: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let version: String?
    public let size: Int64
    /// What removing the foreign code would free.
    public let savings: Int64
    /// How many files inside the bundle carry more than one architecture.
    public let binaryCount: Int
    public let isAppStore: Bool
    /// False when the app belongs to another user or to the system.
    public let isWritable: Bool

    public var id: String { path }
}

/// Removes machine code for architectures this Mac cannot run.
///
/// A universal app carries a complete copy of itself for Apple Silicon and for Intel, and
/// your Mac runs exactly one of them. The other copy is dead weight — several gigabytes
/// across a full Applications folder.
///
/// Two things make this delicate. An app opened through Rosetta needs its Intel copy, so
/// anything deliberately run that way must be left alone. And a signature covers the bytes
/// of the files it seals, which is why every app is verified after the change and put back
/// untouched if the signature no longer holds.
public enum AppSlimming {
    /// Mach-O cpu types. The high bit marks the 64-bit variants.
    static let x86_64: UInt32 = 0x0100_0007
    static let arm64: UInt32 = 0x0100_000C

    #if arch(arm64)
        public static let native = arm64
        public static let nativeName = "arm64"
    #else
        public static let native = x86_64
        public static let nativeName = "x86_64"
    #endif

    public enum Failure: Error, Sendable, Equatable {
        case notWritable
        case running
        case nothingToRemove
        /// The signature no longer held, so everything was put back.
        case signatureBroken(String)
        case failed(String)
    }

    public static var folders: [String] {
        ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path]
    }

    public static func scan(
        folders: [String] = folders, skipping: Set<String> = [Bundle.main.bundlePath]
    ) async -> [SlimmableApp] {
        let paths = AppCatalog.appPaths(in: folders).filter { !skipping.contains($0) }
        var found: [SlimmableApp] = []
        for path in paths {
            guard let app = await inspect(path) else { continue }
            found.append(app)
        }
        return found.sorted { $0.savings > $1.savings }
    }

    static func inspect(_ path: String) async -> SlimmableApp? {
        let binaries = fatBinaries(in: path)
        guard !binaries.isEmpty else { return nil }
        let savings = binaries.reduce(0) { $0 + $1.foreignBytes }
        guard savings > 0 else { return nil }

        let record = await AppCatalog.record(for: path)
        return SlimmableApp(
            path: path,
            name: record?.name ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
            version: record?.version,
            size: record?.size ?? 0,
            savings: savings,
            binaryCount: binaries.count,
            isAppStore: record?.isAppStore ?? false,
            isWritable: access(path, W_OK) == 0
        )
    }

    struct FatBinary {
        let path: String
        let foreignBytes: Int64
    }

    /// Every file in the bundle that holds code for more than one architecture.
    static func fatBinaries(in bundlePath: String) -> [FatBinary] {
        guard let walker = FileManager.default.enumerator(
            at: URL(filePath: bundlePath), includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var found: [FatBinary] = []
        for case let url as URL in walker.allObjects {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let slices = architectures(of: url.path(percentEncoded: false)), slices.count > 1
            else { continue }
            let foreign = slices.filter { $0.cpuType != native }.reduce(Int64(0)) { $0 + Int64($1.size) }
            guard foreign > 0, slices.contains(where: { $0.cpuType == native }) else { continue }
            found.append(FatBinary(path: url.path(percentEncoded: false), foreignBytes: foreign))
        }
        return found
    }

    /// Reads the universal-binary header: the architectures and the bytes each one takes.
    ///
    /// Returns nil for anything that is not one, which is almost every file. Java class files
    /// open with the same four bytes, so the count that follows has to be plausible as well.
    static func architectures(of path: String) -> [(cpuType: UInt32, size: UInt32)]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }

        let magic = be32(header, 0)
        // 0xcafebabe is the 32-bit header, 0xcafebabf the 64-bit one.
        let is64 = magic == 0xCAFE_BABF
        guard magic == 0xCAFE_BABE || is64 else { return nil }
        let count = be32(header, 4)
        guard count > 0, count <= 16 else { return nil }

        let entrySize = is64 ? 32 : 20
        guard let table = try? handle.read(upToCount: entrySize * Int(count)),
              table.count == entrySize * Int(count)
        else { return nil }

        return (0 ..< Int(count)).map { index in
            let base = index * entrySize
            // cputype, cpusubtype, offset, size, align — size is the 4th field.
            let size = is64 ? UInt32(truncatingIfNeeded: be64(table, base + 24)) : be32(table, base + 12)
            return (cpuType: be32(table, base), size: size)
        }
    }

    /// The architectures of any Mach-O, whether it carries several or only one.
    ///
    /// A universal binary opens with a big-endian fat header; a plain one opens with its own
    /// magic and names a single architecture. Telling them apart matters for the opposite
    /// question to slimming: what has *no* native code and so needs Rosetta.
    public static func architectures(ofMachO path: String) -> [UInt32] {
        if let slices = architectures(of: path) { return slices.map(\.cpuType) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return [] }

        // Mach-O headers are written in the byte order of the machine they are for, so both
        // spellings of the magic appear on disk.
        let magic = le32(header, 0)
        guard magic == 0xFEED_FACF || magic == 0xFEED_FACE
            || magic == 0xCFFA_EDFE || magic == 0xCEFA_EDFE
        else { return [] }
        let swapped = magic == 0xCFFA_EDFE || magic == 0xCEFA_EDFE
        return [swapped ? be32(header, 4) : le32(header, 4)]
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

    /// Leaves only this Mac's architecture in every binary of the app.
    ///
    /// The originals are kept aside until the whole bundle has been verified, so a broken
    /// signature costs nothing but the time.
    public static func slim(_ app: SlimmableApp) async -> Result<Int64, Failure> {
        guard app.isWritable else { return .failure(.notWritable) }
        let binaries = fatBinaries(in: app.path)
        guard !binaries.isEmpty else { return .failure(.nothingToRemove) }

        let fileManager = FileManager.default
        let backup = URL(filePath: NSTemporaryDirectory())
            .appending(path: "MacUtil-slim-\(UUID().uuidString)")
        guard (try? fileManager.createDirectory(at: backup, withIntermediateDirectories: true)) != nil else {
            return .failure(.failed("could not prepare a place for the originals"))
        }
        defer { try? fileManager.removeItem(at: backup) }

        var restores: [(original: String, saved: URL)] = []
        func putEverythingBack() {
            for restore in restores {
                try? fileManager.removeItem(atPath: restore.original)
                try? fileManager.moveItem(at: restore.saved, to: URL(filePath: restore.original))
            }
        }

        var freed: Int64 = 0
        for (index, binary) in binaries.enumerated() {
            let thinned = backup.appending(path: "thin-\(index)")
            let saved = backup.appending(path: "orig-\(index)")
            let output = await Command.run(
                "/usr/bin/lipo",
                [binary.path, "-thin", nativeName, "-output", thinned.path(percentEncoded: false)],
                timeout: .seconds(120)
            )
            guard output?.status == 0 else {
                putEverythingBack()
                return .failure(.failed(output?.text ?? "lipo did not finish"))
            }
            do {
                // Keep the executable bit and the rest of the mode the file already had.
                let mode = try fileManager.attributesOfItem(atPath: binary.path)[.posixPermissions]
                try fileManager.moveItem(at: URL(filePath: binary.path), to: saved)
                restores.append((original: binary.path, saved: saved))
                try fileManager.moveItem(at: thinned, to: URL(filePath: binary.path))
                if let mode {
                    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: binary.path)
                }
                freed += binary.foreignBytes
            } catch {
                putEverythingBack()
                return .failure(.failed(error.localizedDescription))
            }
        }

        let check = await Command.run(
            "/usr/bin/codesign", ["--verify", "--strict", app.path], timeout: .seconds(300)
        )
        if check?.status != 0 {
            putEverythingBack()
            return .failure(.signatureBroken(check?.text ?? ""))
        }
        return .success(freed)
    }
}
