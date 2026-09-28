import Foundation

/// A file listed in the file system's own records, whether it still exists or was deleted.
public struct RecordedFile: Sendable, Identifiable, Hashable {
    public let name: String
    /// Folder it was in, as it read inside the card.
    public let folder: String
    public let size: Int64
    public let modified: Date?
    /// Where the contents start, counted in clusters.
    public let firstCluster: UInt32
    /// Written in one piece, so the contents can be read straight through.
    public let isContiguous: Bool
    public let isDeleted: Bool

    public init(
        name: String, folder: String, size: Int64, modified: Date?,
        firstCluster: UInt32, isContiguous: Bool, isDeleted: Bool
    ) {
        self.name = name
        self.folder = folder
        self.size = size
        self.modified = modified
        self.firstCluster = firstCluster
        self.isContiguous = isContiguous
        self.isDeleted = isDeleted
    }

    public var id: String { "\(folder)/\(name)#\(firstCluster)" }
    public var path: String { folder.isEmpty ? name : "\(folder)/\(name)" }
}

/// Reads the records exFAT keeps about its files, including the ones marked deleted.
///
/// A card formatted by a camera or a phone is almost always exFAT. Deleting a file there only
/// clears one flag in its record; the name, the size, the date and the place the contents start
/// all stay behind until something writes over them. That is why this finds files by their real
/// names, in seconds, where reading the whole card byte by byte takes hours and loses the names.
public struct ExFATRecovery: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case notExFAT(String)
        case cannotRead(String)

        public var errorDescription: String? {
            switch self {
            case let .notExFAT(device):
                String(localized: "\(device) is not an exFAT disk, so its own records cannot be read.")
            case let .cannotRead(device):
                String(localized: "MacUtil cannot read \(device).")
            }
        }
    }

    /// Where everything sits on the card, taken from its first sector.
    struct Geometry: Sendable {
        let bytesPerSector: Int
        let sectorsPerCluster: Int
        let fatOffset: Int
        let clusterHeapOffset: Int
        let clusterCount: UInt32
        let rootCluster: UInt32

        var bytesPerCluster: Int { bytesPerSector * sectorsPerCluster }

        /// Clusters are numbered from 2; the first two numbers are reserved.
        func offset(ofCluster cluster: UInt32) -> UInt64 {
            UInt64(clusterHeapOffset) * UInt64(bytesPerSector)
                + UInt64(cluster - 2) * UInt64(bytesPerCluster)
        }
    }

    public init() {}

    /// Lists what the card remembers. Deleted files come first.
    public func scan(
        device: String, includeExisting: Bool = false, includeSystemFiles: Bool = false, limit: Int = 20000
    ) throws -> [RecordedFile] {
        guard let handle = FileHandle(forReadingAtPath: device) else {
            throw errno == EACCES || errno == EPERM ? Failure.cannotRead(device) : Failure.cannotRead(device)
        }
        defer { try? handle.close() }

        let geometry = try Self.geometry(of: handle, device: device)
        var files: [RecordedFile] = []
        var visited = Set<UInt32>()
        try walk(
            directory: geometry.rootCluster, folder: "", handle: handle, geometry: geometry,
            files: &files, visited: &visited, limit: limit
        )
        return files
            .filter { includeExisting || $0.isDeleted }
            .filter { includeSystemFiles || !Self.isHousekeeping($0.name) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Copies a file's contents out of the card, without touching the card itself.
    ///
    /// A file written in one piece is read straight through. A file written in pieces is followed
    /// through the table that records where it continues; if that table no longer holds the file's
    /// chain, which is what deleting usually leaves behind, the clusters are read in order, and
    /// the result may hold parts of something else.
    @discardableResult
    public func restore(_ file: RecordedFile, device: String, to directory: URL) throws -> URL {
        guard let handle = FileHandle(forReadingAtPath: device) else { throw Failure.cannotRead(device) }
        defer { try? handle.close() }

        let geometry = try Self.geometry(of: handle, device: device)
        let destination = TrashRecovery.uniqueURL(in: directory, named: file.name)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let writer = try? FileHandle(forWritingTo: destination) else { throw Failure.cannotRead(device) }
        defer { try? writer.close() }

        var remaining = file.size
        var cluster = file.firstCluster
        var visited = Set<UInt32>()
        while remaining > 0, cluster >= 2, cluster < geometry.clusterCount + 2, visited.insert(cluster).inserted {
            try handle.seek(toOffset: geometry.offset(ofCluster: cluster))
            guard let chunk = try handle.read(upToCount: geometry.bytesPerCluster), !chunk.isEmpty else { break }
            let wanted = Int(min(remaining, Int64(chunk.count)))
            try writer.write(contentsOf: chunk.prefix(wanted))
            remaining -= Int64(wanted)

            if file.isContiguous {
                cluster += 1
            } else if let next = try Self.nextCluster(after: cluster, handle: handle, geometry: geometry) {
                cluster = next
            } else {
                // The chain is gone, as it usually is once a file is deleted.
                cluster += 1
            }
        }
        return destination
    }

    /// Where a file continues, according to the table exFAT keeps for that.
    static func nextCluster(after cluster: UInt32, handle: FileHandle, geometry: Geometry) throws -> UInt32? {
        let offset = UInt64(geometry.fatOffset) * UInt64(geometry.bytesPerSector) + UInt64(cluster) * 4
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return nil }
        return chainEntry([UInt8](data), clusterCount: geometry.clusterCount)
    }

    /// Reads one entry of the table. Zero means unused, and the end marker means the file stops here.
    static func chainEntry(_ bytes: [UInt8], clusterCount: UInt32) -> UInt32? {
        let value = read32(bytes, 0)
        guard value >= 2, value < clusterCount + 2, value != 0xFFFF_FFFF else { return nil }
        return value
    }

    /// macOS leaves its own small files on a card next to yours; they are noise here.
    static func isHousekeeping(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name.hasPrefix(".Spotlight")
            || name.hasPrefix(".fseventsd") || name == ".Trashes" || name == ".TemporaryItems"
    }

    // MARK: - Reading the card

    static func geometry(of handle: FileHandle, device: String) throws -> Geometry {
        try handle.seek(toOffset: 0)
        guard let boot = try handle.read(upToCount: 512), boot.count == 512 else {
            throw Failure.cannotRead(device)
        }
        let bytes = [UInt8](boot)
        guard Array(bytes[3 ..< 11]) == Array("EXFAT   ".utf8) else { throw Failure.notExFAT(device) }

        let sectorShift = Int(bytes[108])
        let clusterShift = Int(bytes[109])
        guard sectorShift >= 9, sectorShift <= 12, clusterShift <= 25 else { throw Failure.notExFAT(device) }
        return Geometry(
            bytesPerSector: 1 << sectorShift,
            sectorsPerCluster: 1 << clusterShift,
            fatOffset: Int(read32(bytes, 80)),
            clusterHeapOffset: Int(read32(bytes, 88)),
            clusterCount: read32(bytes, 92),
            rootCluster: read32(bytes, 96)
        )
    }

    /// Walks a directory and the directories inside it, collecting every record.
    private func walk(
        directory cluster: UInt32, folder: String, handle: FileHandle, geometry: Geometry,
        files: inout [RecordedFile], visited: inout Set<UInt32>, limit: Int, depth: Int = 0
    ) throws {
        guard depth < 12, files.count < limit, visited.insert(cluster).inserted,
              cluster >= 2, cluster < geometry.clusterCount + 2
        else { return }

        var current = cluster
        var clustersRead = 0
        var pending: [(RecordedFile, isDirectory: Bool)] = []

        // A directory runs on for as many clusters as it needs; they follow one another.
        while clustersRead < 64, current >= 2, current < geometry.clusterCount + 2 {
            try handle.seek(toOffset: geometry.offset(ofCluster: current))
            guard let data = try handle.read(upToCount: geometry.bytesPerCluster), data.count >= 32 else { break }
            let bytes = [UInt8](data)

            var index = 0
            var stop = false
            while index + 32 <= bytes.count {
                let entry = Array(bytes[index ..< index + 32])
                switch entry[0] {
                case 0x00:
                    // Nothing has ever been written past here.
                    stop = true
                case 0x85, 0x05:
                    if let file = Self.readFile(at: index, in: bytes, folder: folder, geometry: geometry) {
                        pending.append((file.0, file.isDirectory))
                        index += (1 + Int(entry[1])) * 32
                        continue
                    }
                default:
                    break
                }
                if stop { break }
                index += 32
            }
            if stop { break }
            clustersRead += 1
            current += 1
        }

        for (file, isDirectory) in pending {
            if isDirectory {
                try walk(
                    directory: file.firstCluster, folder: file.path, handle: handle, geometry: geometry,
                    files: &files, visited: &visited, limit: limit, depth: depth + 1
                )
            } else if file.size > 0 {
                files.append(file)
            }
            if files.count >= limit { return }
        }
    }

    /// Reads one file out of the three records exFAT keeps for it: the file itself,
    /// its stream, and its name in pieces of fifteen characters.
    static func readFile(
        at index: Int, in bytes: [UInt8], folder: String, geometry: Geometry
    ) -> (RecordedFile, isDirectory: Bool)? {
        let entry = Array(bytes[index ..< index + 32])
        let isDeleted = entry[0] == 0x05
        let secondaries = Int(entry[1])
        guard secondaries >= 2, index + (1 + secondaries) * 32 <= bytes.count else { return nil }

        let attributes = Int(entry[4]) | Int(entry[5]) << 8
        let isDirectory = attributes & 0x10 != 0
        let modified = dosDate(read32(entry, 12))

        let stream = Array(bytes[(index + 32) ..< (index + 64)])
        guard stream[0] == 0xC0 || stream[0] == 0x40 else { return nil }
        let flags = stream[1]
        let nameLength = Int(stream[3])
        let firstCluster = read32(stream, 20)
        let size = Int64(read64(stream, 24))
        guard firstCluster >= 2, nameLength > 0, nameLength <= 255 else { return nil }

        var scalars: [UInt16] = []
        for part in 1 ..< secondaries {
            let start = index + (1 + part) * 32
            guard start + 32 <= bytes.count else { break }
            let piece = Array(bytes[start ..< start + 32])
            guard piece[0] == 0xC1 || piece[0] == 0x41 else { continue }
            for character in stride(from: 2, to: 32, by: 2) {
                scalars.append(UInt16(piece[character]) | UInt16(piece[character + 1]) << 8)
            }
        }
        let name = String(decoding: scalars.prefix(nameLength), as: UTF16.self)
        guard !name.isEmpty, !name.contains("\0") else { return nil }

        return (
            RecordedFile(
                name: name, folder: folder, size: size, modified: modified,
                firstCluster: firstCluster,
                // Bit 1 of the flags means the contents lie in one piece.
                isContiguous: flags & 0x02 != 0,
                isDeleted: isDeleted
            ),
            isDirectory
        )
    }

    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        return (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// exFAT writes dates the way MS-DOS did: packed into four bytes.
    static func dosDate(_ raw: UInt32) -> Date? {
        let time = UInt16(raw & 0xFFFF)
        let date = UInt16(raw >> 16)
        guard date != 0 else { return nil }
        var components = DateComponents()
        components.year = 1980 + Int(date >> 9)
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
