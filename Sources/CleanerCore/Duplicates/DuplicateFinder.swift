import CryptoKit
import Darwin
import Foundation
import Synchronization

public struct DuplicateFile: Sendable, Identifiable, Hashable {
    public let path: String
    public let modificationDate: Date
    /// Bytes that only this file uses. Zero for an APFS clone whose blocks are
    /// shared with a copy, so deleting it would free nothing.
    public let privateSize: Int64

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public let hash: String
    /// Size of each copy.
    public let size: Int64
    public let files: [DuplicateFile]

    public var id: String { hash }
    public var kind: FileKind { FileKind(fileName: files.first?.name ?? "") }

    /// Space freed by keeping just one copy.
    public var reclaimableSize: Int64 {
        guard let keep = files.max(by: { $0.privateSize < $1.privateSize }) else { return 0 }
        return freedSpace(removing: Set(files.map(\.path)).subtracting([keep.path]))
    }

    /// Space freed by removing these copies. Clones share blocks, which are freed
    /// only once no remaining copy uses them (assumes one clone family per group).
    public func freedSpace(removing paths: Set<String>) -> Int64 {
        occupied(files) - occupied(files.filter { !paths.contains($0.path) })
    }

    private func occupied(_ copies: [DuplicateFile]) -> Int64 {
        let own = copies.reduce(0) { $0 + $1.privateSize }
        let sharesBlocks = copies.contains { $0.privateSize < size * 9 / 10 }
        return own + (sharesBlocks ? size : 0)
    }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case scanning, comparing, done
    }

    public var stage = Stage.scanning
    public var filesScanned = 0
    public var candidates = 0
    public var hashed = 0

    public init() {}
}

/// Finds files with identical contents.
///
/// Files are grouped by size first, then by a hash of their first and last
/// 64 KB, and only the remaining candidates are hashed in full. Hard links are
/// one file, not duplicates; iCloud placeholders are never read.
public final class DuplicateFinder: Sendable {
    public let minimumSize: Int64
    public let excludedPaths: Set<String>
    private let state = Mutex(DuplicateProgress())
    private let scanner: DiskScanner

    public init(minimumSize: Int64 = 1_000_000, excludedPaths: Set<String> = []) {
        self.minimumSize = minimumSize
        self.excludedPaths = excludedPaths
        var options = ScanOptions()
        options.excludedPaths = excludedPaths
        scanner = DiskScanner(options: options)
    }

    public var progress: DuplicateProgress {
        var progress = state.withLock { $0 }
        if progress.stage == .scanning {
            progress.filesScanned = scanner.progress.files
        }
        return progress
    }

    public func cancel() {
        scanner.cancel()
    }

    public func find(in root: URL) async throws -> [DuplicateGroup] {
        let tree = try await scanner.scan(root).root

        // 1. Same size, regular files, contents on this Mac, outside packages such as .app bundles.
        var bySize: [Int64: [String]] = [:]
        var stack = [tree]
        while let node = stack.popLast() {
            for directory in node.directories where !directory.isPackage && !directory.name.hasPrefix(".") {
                stack.append(directory)
            }
            for file in node.files where file.type == .regular && !file.isDataless && !file.name.hasPrefix(".")
                && file.logicalSize >= minimumSize
            {
                bySize[file.logicalSize, default: []].append(node.path(of: file))
            }
        }
        let sizeGroups = bySize.filter { $0.value.count > 1 }
        state.withLock {
            $0.stage = .comparing
            $0.filesScanned = tree.fileCount
            $0.candidates = sizeGroups.values.reduce(0) { $0 + $1.count }
        }

        // 2 and 3. Quick hash of both ends, then a full hash, in parallel.
        let groups = try await withThrowingTaskGroup(of: [DuplicateGroup].self) { group in
            for (size, paths) in sizeGroups {
                group.addTask { try self.compare(paths, size: size) }
            }
            var all: [DuplicateGroup] = []
            for try await found in group {
                all += found
            }
            return all
        }
        state.withLock { $0.stage = .done }
        return groups.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    private func compare(_ paths: [String], size: Int64) throws -> [DuplicateGroup] {
        if scanner.isCancelled {
            throw CancellationError()
        }
        let unique = Self.removingHardLinks(paths)
        guard unique.count > 1 else { return [] }

        var byQuickHash: [String: [String]] = [:]
        for path in unique {
            if let hash = Self.quickHash(path, size: size) {
                byQuickHash[hash, default: []].append(path)
            }
        }
        var groups: [DuplicateGroup] = []
        for candidates in byQuickHash.values where candidates.count > 1 {
            var byFullHash: [String: [String]] = [:]
            for path in candidates {
                if scanner.isCancelled {
                    throw CancellationError()
                }
                if let hash = Self.fullHash(path) {
                    byFullHash[hash, default: []].append(path)
                }
                state.withLock { $0.hashed += 1 }
            }
            for (hash, identical) in byFullHash where identical.count > 1 {
                groups.append(DuplicateGroup(hash: hash, size: size, files: identical.map(Self.describe)))
            }
        }
        return groups
    }

    // MARK: - Helpers

    static func removingHardLinks(_ paths: [String]) -> [String] {
        var seen = Set<[UInt64]>()
        return paths.filter { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            return seen.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted
        }
    }

    static func quickHash(_ path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            guard let tail = try? handle.read(upToCount: chunk) else { return nil }
            hasher.update(data: tail)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ path: String) -> DuplicateFile {
        var info = stat()
        lstat(path, &info)
        return DuplicateFile(
            path: path,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            privateSize: privateSize(path) ?? Int64(info.st_blocks) * 512
        )
    }

    /// Bytes not shared with APFS clones (`ATTR_CMNEXT_PRIVATESIZE`).
    static func privateSize(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = ATTR_CMN_RETURNED_ATTRS
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(path, &request, $0.baseAddress, 64, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: off_t.self)
        }
    }
}

/// Picks which copies to remove, always keeping at least one per group.
public enum DuplicateSelection: String, Sendable, CaseIterable {
    case keepOldest, keepNewest, keepShortestPath

    public func filesToRemove(in group: DuplicateGroup) -> [DuplicateFile] {
        let keep: DuplicateFile? = switch self {
        case .keepOldest: group.files.min { $0.modificationDate < $1.modificationDate }
        case .keepNewest: group.files.max { $0.modificationDate < $1.modificationDate }
        case .keepShortestPath: group.files.min { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
        }
        return group.files.filter { $0.path != keep?.path }
    }
}
