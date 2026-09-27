import CryptoKit
import Foundation

/// A kind of file the carver can recognise by the bytes it starts with.
public struct FileSignature: Sendable, Hashable {
    public let name: String
    public let fileExtension: String
    /// Bytes every file of this kind starts with.
    public let magic: [UInt8]
    /// Bytes that end it, when the format has such a marker.
    public let trailer: [UInt8]?
    /// How far to keep reading before giving up on finding the end.
    public let maximumSize: Int

    public static let all: [FileSignature] = [
        FileSignature(
            name: "JPEG image", fileExtension: "jpg",
            magic: [0xFF, 0xD8, 0xFF], trailer: [0xFF, 0xD9], maximumSize: 64 << 20
        ),
        FileSignature(
            name: "PNG image", fileExtension: "png",
            magic: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            trailer: [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82], maximumSize: 64 << 20
        ),
        FileSignature(
            name: "GIF image", fileExtension: "gif",
            magic: Array("GIF8".utf8), trailer: [0x00, 0x3B], maximumSize: 32 << 20
        ),
        FileSignature(
            name: "PDF document", fileExtension: "pdf",
            magic: Array("%PDF-".utf8), trailer: Array("%%EOF".utf8), maximumSize: 256 << 20
        ),
        // Office documents, Keynote, Pages and Numbers files are all zip archives.
        FileSignature(
            name: "Zip archive or Office document", fileExtension: "zip",
            magic: [0x50, 0x4B, 0x03, 0x04], trailer: nil, maximumSize: 256 << 20
        ),
        FileSignature(
            name: "MP4 or MOV video", fileExtension: "mp4",
            magic: Array("ftyp".utf8), trailer: nil, maximumSize: 4 << 30
        ),
        FileSignature(
            name: "HEIC image", fileExtension: "heic",
            magic: Array("ftypheic".utf8), trailer: nil, maximumSize: 128 << 20
        ),
        FileSignature(
            name: "MP3 audio", fileExtension: "mp3",
            magic: Array("ID3".utf8), trailer: nil, maximumSize: 256 << 20
        ),
        FileSignature(
            name: "SQLite database", fileExtension: "sqlite",
            magic: Array("SQLite format 3\0".utf8), trailer: nil, maximumSize: 1 << 30
        ),
    ]

    /// JPEG's three magic bytes alone match random data, so the fourth byte has to be a
    /// real marker. Formats carried inside an ISO container start 4 bytes in.
    var offsetFromMatch: Int { name.hasPrefix("MP4") || name.hasPrefix("HEIC") ? -4 : 0 }

    func looksReal(_ window: ArraySlice<UInt8>) -> Bool {
        guard name.hasPrefix("JPEG") else { return true }
        guard let marker = window.dropFirst(3).first else { return false }
        return [0xE0, 0xE1, 0xDB, 0xEE, 0xE2, 0xED].contains(marker)
    }
}

/// A file found by scanning the raw bytes of a disk.
public struct CarvedFile: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let signature: String
    public let fileExtension: String
    /// Where the file starts on the device, in bytes.
    public let offset: Int64
    public let size: Int64
    public let sha256: String
    /// Set once the file has been written somewhere safe.
    public var recoveredTo: String?
    /// True when a file with the same contents is still on the volume, so nothing was lost.
    public var isStillOnDisk: Bool

    public var suggestedName: String {
        "recovered-\(String(format: "%010lld", offset)).\(fileExtension)"
    }
}

/// Finds deleted files by reading a disk byte by byte and looking for the shapes files start with.
///
/// This works on flash drives, memory cards, external disks and disk images. It cannot work on
/// the internal SSD of a modern Mac: macOS tells the drive to discard deleted blocks, and
/// FileVault encrypts what is left, so there is nothing recognisable to find.
public struct FileCarver: Sendable {
    public struct Progress: Sendable, Equatable {
        public var bytesScanned: Int64 = 0
        public var totalBytes: Int64 = 0
        public var found = 0

        public var fraction: Double {
            totalBytes > 0 ? min(1, Double(bytesScanned) / Double(totalBytes)) : 0
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case cannotRead(String)
        case notAllowed(String)

        public var errorDescription: String? {
            switch self {
            case let .cannotRead(device):
                String(localized: "MacUtil cannot read \(device).")
            case let .notAllowed(device):
                String(localized: "Reading \(device) needs an administrator password.")
            }
        }
    }

    public let signatures: [FileSignature]
    /// Reading is done in whole blocks, as raw devices require.
    let blockSize = 4 << 20

    public init(signatures: [FileSignature] = FileSignature.all) {
        self.signatures = signatures
    }

    /// Scans a device or image file and returns what it recognised, newest read first.
    /// `output` is where recovered files are written; it must be on another disk.
    public func scan(
        device: String,
        output: URL?,
        limit: Int = 500,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [CarvedFile] {
        guard let handle = FileHandle(forReadingAtPath: device) else {
            throw errno == EACCES || errno == EPERM ? Failure.notAllowed(device) : Failure.cannotRead(device)
        }
        defer { try? handle.close() }

        var state = Progress()
        state.totalBytes = Self.size(ofDevice: device)
        var found: [CarvedFile] = []
        var carry = Data()
        var carryOffset: Int64 = 0
        /// Where the file found last ends, so its insides are not scanned again.
        var lastEnd: Int64 = 0
        let longestMagic = signatures.map(\.magic.count).max() ?? 8

        while !Task.isCancelled, found.count < limit {
            guard let chunk = try handle.read(upToCount: blockSize), !chunk.isEmpty else { break }
            let window = carry + chunk
            let windowStart = carryOffset

            for (start, signature) in matches(in: window) {
                guard found.count < limit else { break }
                let offset = windowStart + Int64(start)
                // A file already found in the previous chunk's tail would come up twice.
                guard offset >= lastEnd else { continue }
                if let file = try extract(
                    signature, from: handle, deviceOffset: offset, output: output
                ) {
                    found.append(file)
                    state.found = found.count
                    lastEnd = offset + file.size
                }
            }

            state.bytesScanned += Int64(chunk.count)
            progress(state)
            // Keep the tail so a signature split across two reads is still seen.
            carry = window.suffix(longestMagic)
            carryOffset = state.bytesScanned - Int64(carry.count)
        }
        return found
    }

    /// Where each known signature starts inside one chunk, in order.
    /// `Data.range(of:)` does the searching, which is far faster than walking bytes in Swift.
    func matches(in window: Data) -> [(offset: Int, signature: FileSignature)] {
        var results: [(Int, FileSignature)] = []
        for signature in signatures {
            let magic = Data(signature.magic)
            var searchStart = window.startIndex
            while searchStart < window.endIndex,
                  let range = window.range(of: magic, in: searchStart ..< window.endIndex)
            {
                let index = window.distance(from: window.startIndex, to: range.lowerBound)
                let tail = Array(window[range.lowerBound ..< min(window.endIndex, range.lowerBound + 8)])
                if signature.looksReal(tail[...]), index + signature.offsetFromMatch >= 0 {
                    results.append((index + signature.offsetFromMatch, signature))
                }
                searchStart = range.upperBound
            }
        }
        return results.sorted { $0.0 < $1.0 }
    }

    func matchingSignature(in bytes: [UInt8], at index: Int) -> FileSignature? {
        for signature in signatures {
            let end = index + signature.magic.count
            guard end <= bytes.count else { continue }
            guard Array(bytes[index ..< end]) == signature.magic else { continue }
            guard signature.looksReal(bytes[index...]) else { continue }
            return signature
        }
        return nil
    }

    /// Reads from the start of a file until its end marker or its size limit.
    private func extract(
        _ signature: FileSignature, from handle: FileHandle, deviceOffset: Int64, output: URL?
    ) throws -> CarvedFile? {
        let saved = try handle.offset()
        defer { try? handle.seek(toOffset: saved) }

        // Raw devices only accept reads that start on a block boundary.
        let alignment = Int64(512)
        let alignedStart = (deviceOffset / alignment) * alignment
        let skip = Int(deviceOffset - alignedStart)
        try handle.seek(toOffset: UInt64(alignedStart))

        var data = Data()
        var end: Int?
        while data.count < signature.maximumSize {
            guard let chunk = try handle.read(upToCount: blockSize), !chunk.isEmpty else { break }
            data.append(chunk)
            if let trailer = signature.trailer {
                let searchFrom = max(0, data.count - chunk.count - trailer.count)
                if let range = data.range(of: Data(trailer), in: searchFrom ..< data.count) {
                    end = data.distance(from: data.startIndex, to: range.upperBound)
                    break
                }
            }
            if signature.trailer == nil, data.count >= 8 << 20 { break }
        }
        guard data.count > skip else { return nil }
        let contents = data.subdata(in: skip ..< (end ?? min(data.count, defaultSize(for: signature))))
        guard contents.count >= 512 else { return nil }

        var file = CarvedFile(
            id: UUID(), signature: signature.name, fileExtension: signature.fileExtension,
            offset: deviceOffset, size: Int64(contents.count),
            sha256: SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined(),
            recoveredTo: nil, isStillOnDisk: false
        )
        if let output {
            let destination = output.appending(path: file.suggestedName)
            try contents.write(to: destination)
            file.recoveredTo = destination.path
        }
        return file
    }

    /// Formats without an end marker are cut at a size that keeps the useful part.
    private func defaultSize(for signature: FileSignature) -> Int {
        min(signature.maximumSize, 8 << 20)
    }

    /// Size of a device in bytes, so progress has something to count against.
    static func size(ofDevice path: String) -> Int64 {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int64, size > 0
        {
            return size
        }
        let handle = FileHandle(forReadingAtPath: path)
        defer { try? handle?.close() }
        return Int64((try? handle?.seekToEnd()) ?? 0)
    }
}
