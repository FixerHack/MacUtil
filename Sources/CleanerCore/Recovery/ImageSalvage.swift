import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Checks whether a recovered picture actually opens, and rescues what it can when it does not.
///
/// A file pulled off a disk by its shape can start out right and then run into someone else's
/// data, which happens when the original was written in pieces. Such a file still ends the way a
/// picture should, so only a decoder can tell it apart from a whole one.
public enum ImageSalvage {
    public enum Verdict: Sendable, Equatable {
        /// Opens completely.
        case whole
        /// Only the top of the picture survived; the rescued part is attached.
        case partial(Data)
        /// Nothing could be read out of it.
        case damaged
    }

    /// Extensions worth checking. Other formats are left as they are.
    public static let supported: Set<String> = ["jpg", "png", "heic", "gif"]

    public static func inspect(_ data: Data, fileExtension: String) -> Verdict {
        guard supported.contains(fileExtension) else { return .whole }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .damaged }

        if CGImageSourceGetStatus(source) == .statusComplete,
           CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        {
            return .whole
        }
        // Reading it as if it were still arriving gives back the part that did arrive.
        if let rescued = salvage(data) { return .partial(rescued) }
        // When a photo was written in pieces, often only its header survives at this spot. The
        // header carries the small preview the camera stored, which at least shows what the
        // picture was.
        if let preview = embeddedPreview(in: data) { return .partial(preview) }
        return .damaged
    }

    /// The preview a camera stores inside a photo's header, when that header is all that is left.
    static func embeddedPreview(in data: Data, searchLimit: Int = 256 * 1024) -> Data? {
        let bytes = [UInt8](data.prefix(searchLimit))
        var index = 2
        while index + 4 < bytes.count {
            // A nested picture starts the same way the file does.
            guard bytes[index] == 0xFF, bytes[index + 1] == 0xD8,
                  bytes[index + 2] == 0xFF, [0xE0, 0xE1, 0xDB, 0xC4].contains(bytes[index + 3])
            else {
                index += 1
                continue
            }
            var end = index + 4
            while end + 1 < bytes.count {
                if bytes[end] == 0xFF, bytes[end + 1] == 0xD9 {
                    let preview = Data(bytes[index ..< (end + 2)])
                    if preview.count > 512,
                       let source = CGImageSourceCreateWithData(preview as CFData, nil),
                       CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
                    {
                        return preview
                    }
                    break
                }
                end += 1
            }
            index += 2
        }
        return nil
    }

    /// Decodes as much of the picture as the data allows and writes it out as a new JPEG.
    static func salvage(_ data: Data) -> Data? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, true)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 16, image.height > 16
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
