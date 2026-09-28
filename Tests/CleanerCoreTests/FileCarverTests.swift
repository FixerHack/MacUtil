@testable import CleanerCore
import CoreGraphics
import CryptoKit
import ImageIO
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

    /// A photo the way a camera writes one: a small preview tucked inside, then the picture.
    private func makePhotoWithThumbnail() -> Data {
        var thumbnail = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 0x00, 0x00])
        thumbnail.append(Data((0 ..< 2000).map { UInt8(($0 &* 17 &+ 3) % 250) }))
        thumbnail.append(Data([0xFF, 0xD9]))

        var exif = Data("Exif\0\0".utf8)
        exif.append(thumbnail)
        let length = exif.count + 2

        var photo = Data([0xFF, 0xD8])
        photo.append(Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]))
        photo.append(exif)
        // Start of scan, then the picture data, with FF escaped the way JPEG requires.
        photo.append(Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]))
        for index in 0 ..< 40000 {
            let byte = UInt8((index &* 13 &+ 7) % 255)
            photo.append(byte)
            if byte == 0xFF { photo.append(0x00) }
        }
        photo.append(Data([0xFF, 0xD9]))
        return photo
    }

    @Test func readsAPhotoPastItsPreviewPicture() throws {
        let photo = makePhotoWithThumbnail()
        let end = try #require(FileCarver.jpegEnd(in: [UInt8](photo), from: 0))

        // Stopping at the preview's ending would give a few kilobytes instead of the photo.
        #expect(end == photo.count)
        #expect(end > 40000)
    }

    @Test func readsTheSizeOutOfASQLiteHeader() throws {
        var header = [UInt8]("SQLite format 3\0".utf8)
        header += [0x10, 0x00] // page size 4096
        header += [UInt8](repeating: 0, count: 10)
        header += [0x00, 0x00, 0x00, 0x03] // three pages
        header += [UInt8](repeating: 0, count: 64)

        #expect(FileCarver.sqliteEnd(in: header, from: 0) == 3 * 4096)
    }

    @Test func walksTheBoxesOfAVideo() {
        // Two boxes: 16 bytes and 32 bytes.
        var bytes: [UInt8] = [0, 0, 0, 16] + [UInt8]("ftyp".utf8) + [UInt8](repeating: 0, count: 8)
        bytes += [0, 0, 0, 32] + [UInt8]("mdat".utf8) + [UInt8](repeating: 7, count: 24)

        #expect(FileCarver.isoContainerEnd(in: bytes, from: 0) == 48)
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

        let original = makePhotoWithThumbnail()
        let expected = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let file = URL(filePath: mountPoint).appending(path: "holiday.jpg")
        try original.write(to: file)
        try FileManager.default.removeItem(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // The raw device shows what the file system no longer lists.
        let raw = "/dev/r" + (device as NSString).lastPathComponent
        let found = try await FileCarver().scan(device: raw, output: output)
        _ = await DiskImages.detach(device, force: true)

        // One photo, not the photo plus the preview inside it.
        #expect(found.filter { $0.fileExtension == "jpg" }.count == 1)
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

struct ImageSalvageTests {
    /// A picture that opens, made the way a camera's preview is stored.
    private func tinyJPEG() -> Data {
        let pixel = CGImage(
            width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(repeating: 0x7F, count: 32 * 32 * 4) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pixel, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test func callsAWorkingPictureWhole() {
        #expect(ImageSalvage.inspect(tinyJPEG(), fileExtension: "jpg") == .whole)
    }

    @Test func findsThePreviewInsideABrokenPhoto() throws {
        // A header with a preview inside it, then data belonging to something else.
        var broken = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10] + Array("Exif\0\0".utf8))
        broken.append(tinyJPEG())
        broken.append(Data((0 ..< 40000).map { UInt8($0 % 251) }))
        broken.append(Data([0xFF, 0xD9]))

        let verdict = ImageSalvage.inspect(broken, fileExtension: "jpg")
        guard case let .partial(rescued) = verdict else {
            Issue.record("expected the preview to be rescued, got \(verdict)")
            return
        }
        let source = try #require(CGImageSourceCreateWithData(rescued as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    @Test func callsRandomDataDamaged() {
        let noise = Data([0xFF, 0xD8, 0xFF, 0xE0] + (0 ..< 20000).map { UInt8($0 % 255) } + [0xFF, 0xD9])
        #expect(ImageSalvage.inspect(noise, fileExtension: "jpg") == .damaged)
    }

    @Test func leavesFormatsItCannotOpenAlone() {
        #expect(ImageSalvage.inspect(Data([1, 2, 3]), fileExtension: "zip") == .whole)
    }
}
