@testable import CleanerCore
import CryptoKit
import Foundation
import Testing

/// Recovery is tried on a disk image the test makes, never on a real disk.
@Suite(.serialized) struct FileCarverTests {
    /// A JPEG the carver should recognise: real markers, random middle, proper ending.
    private func makeJPEG(bytes: Int = 300_000) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0x00])
        data.append(Data((0 ..< bytes).map { UInt8(($0 &* 31 &+ 7) % 251) }))
        data.append(Data([0xFF, 0xD9]))
        return data
    }

    @Test func findsTheStartOfKnownFormats() {
        let carver = FileCarver()
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]
        #expect(carver.matchingSignature(in: png, at: 0)?.fileExtension == "png")

        let pdf = [UInt8]("%PDF-1.7 hello".utf8)
        #expect(carver.matchingSignature(in: pdf, at: 0)?.fileExtension == "pdf")

        // Three JPEG bytes alone turn up in random data; a real file has a marker after them.
        #expect(carver.matchingSignature(in: [0xFF, 0xD8, 0xFF, 0xD9, 0x00], at: 0) == nil)
        #expect(carver.matchingSignature(in: [0xFF, 0xD8, 0xFF, 0xE1, 0x00], at: 0)?.fileExtension == "jpg")
    }

    @Test func recoversADeletedFileFromAnImage() async throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "mu-carve-\(UUID().uuidString).dmg")
        let output = FileManager.default.temporaryDirectory.appending(path: "mu-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: output)
        }

        // ExFAT, like a camera card: deleting a file leaves its contents in place.
        let created = await DiskImages.create(
            at: image, volumeName: "MUCarve", size: 120 * 1024 * 1024, format: .exFAT
        )
        try #require(created.succeeded)
        let (outcome, attached) = await DiskImages.attach(image)
        try #require(outcome.succeeded)
        let device = try #require(attached?.device)
        let mountPoint = try #require(attached?.mountPoint)
        defer { Task { _ = await DiskImages.detach(device, force: true) } }

        let original = makeJPEG()
        let expected = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let file = URL(filePath: mountPoint).appending(path: "holiday.jpg")
        try original.write(to: file)
        try FileManager.default.removeItem(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // The raw device shows what the file system no longer lists.
        let raw = "/dev/r" + (device as NSString).lastPathComponent
        let found = try await FileCarver().scan(device: raw, output: output)
        _ = await DiskImages.detach(device, force: true)

        let jpeg = try #require(found.filter { $0.fileExtension == "jpg" }.first)
        #expect(jpeg.sha256 == expected)
        #expect(jpeg.size == Int64(original.count))
        let recovered = try #require(jpeg.recoveredTo)
        #expect(try Data(contentsOf: URL(filePath: recovered)) == original)
    }

    @Test func saysWhenItIsNotAllowedToRead() async {
        // Physical disks belong to root, so reading them needs a password.
        await #expect(throws: FileCarver.Failure.notAllowed("/dev/rdisk0")) {
            _ = try await FileCarver().scan(device: "/dev/rdisk0", output: nil, limit: 1)
        }
    }
}
