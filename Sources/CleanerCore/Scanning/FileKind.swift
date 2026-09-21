import Foundation

/// Rough file category by extension, used for colors and filters.
public enum FileKind: String, CaseIterable, Sendable {
    case image, video, audio, archive, diskImage, application, document, code, other

    public init(fileName: String) {
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        self = Self.byExtension[pathExtension] ?? .other
    }

    private static let byExtension: [String: FileKind] = {
        let groups: [FileKind: [String]] = [
            .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "cr2", "cr3",
                     "nef", "arw", "dng", "psd", "svg", "ico", "icns", "avif"],
            .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "mts"],
            .audio: ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "ogg", "opus", "wma", "caf", "alac"],
            .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "cpio", "xip"],
            .diskImage: ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "vdi", "qcow2", "ipsw", "raw",
                         "vhd", "vhdx"],
            .application: ["app", "pkg", "mpkg", "ipa", "apk", "exe", "msi"],
            .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt",
                        "rtf", "md", "csv", "epub", "odt", "ods"],
            .code: ["swift", "c", "h", "m", "mm", "cpp", "hpp", "py", "js", "ts", "tsx", "jsx", "json", "xml",
                    "html", "css", "java", "kt", "go", "rs", "rb", "sh", "sql", "yml", "yaml", "php"],
        ]
        var map: [String: FileKind] = [:]
        for (kind, extensions) in groups {
            for pathExtension in extensions {
                map[pathExtension] = kind
            }
        }
        return map
    }()
}
