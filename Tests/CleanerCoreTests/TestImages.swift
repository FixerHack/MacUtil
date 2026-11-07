@testable import CleanerCore
import Foundation

/// Makes a disk image for a test, with one more try when hdiutil turns it down.
///
/// Now and then, under a full test run on a busy Mac, `hdiutil create` fails with
/// 0xf8da0001 and nothing more to go on. It never failed in 114 creates outside the test
/// runner, one after another, side by side, or mixed with attaching and force-detaching,
/// so there was nothing in the call itself to fix. None of these tests is about creating
/// the image, so a second try hides nothing they check; a second refusal still fails, with
/// hdiutil's own words in the outcome.
enum TestImages {
    static func create(
        at url: URL, volumeName: String, size: Int64, format: DiskFormat = .apfs
    ) async -> DiskOperations.Outcome {
        let first = await DiskImages.create(at: url, volumeName: volumeName, size: size, format: format)
        guard !first.succeeded else { return first }
        try? FileManager.default.removeItem(at: url)
        try? await Task.sleep(for: .seconds(1))
        return await DiskImages.create(at: url, volumeName: volumeName, size: size, format: format)
    }
}
