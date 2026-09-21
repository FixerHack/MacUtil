import CleanerCore
import SwiftUI

extension FileKind {
    var title: LocalizedStringKey {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .archive: "Archives"
        case .diskImage: "Disk Images"
        case .application: "Apps & Installers"
        case .document: "Documents"
        case .code: "Code"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .archive: "doc.zipper"
        case .diskImage: "opticaldiscdrive"
        case .application: "app.dashed"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }

    var color: Color {
        switch self {
        case .image: .teal
        case .video: .pink
        case .audio: .orange
        case .archive: .brown
        case .diskImage: .indigo
        case .application: .blue
        case .document: .green
        case .code: .mint
        case .other: .gray
        }
    }
}

/// Finder actions shared by the file lists.
enum FinderActions {
    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
    }

    static func copy(_ paths: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
