import CleanerCore
import SwiftUI

/// One tile in Space Lens: a folder, a file, or the leftover small items grouped together.
struct LensItem: Identifiable {
    enum Content {
        case directory(DirectoryNode)
        case file(FileEntry)
        case others(count: Int)
    }

    let id: String
    let name: String
    let size: Int64
    let content: Content
    let color: Color

    var path: String? {
        switch content {
        case .directory, .file: id
        case .others: nil
        }
    }

    var directory: DirectoryNode? {
        if case let .directory(node) = content {
            node
        } else {
            nil
        }
    }

    private static let folderColors: [Color] = [
        .blue,
        .purple,
        .teal,
        .orange,
        .pink,
        .indigo,
        .green,
        .cyan,
        .mint,
        .brown,
    ]

    /// The biggest children of `node`, with the rest merged into one "others" item.
    static func items(in node: DirectoryNode, limit: Int = 48) -> [LensItem] {
        var items: [LensItem] = []
        var folderIndex = 0
        var directories = node.directories.makeIterator()
        var files = node.files.makeIterator()
        var nextDirectory = directories.next()
        var nextFile = files.next()

        // Both arrays are sorted by size, so merge them.
        while items.count < limit {
            let takeDirectory: Bool
            switch (nextDirectory, nextFile) {
            case let (directory?, file?): takeDirectory = directory.allocatedSize >= file.allocatedSize
            case (.some, nil): takeDirectory = true
            case (nil, .some): takeDirectory = false
            case (nil, nil): return items
            }
            if takeDirectory, let directory = nextDirectory {
                guard directory.allocatedSize > 0 else { break }
                items.append(LensItem(
                    id: directory.path,
                    name: directory.name,
                    size: directory.allocatedSize,
                    content: .directory(directory),
                    color: folderColors[folderIndex % folderColors.count]
                ))
                folderIndex += 1
                nextDirectory = directories.next()
            } else if let file = nextFile {
                guard file.allocatedSize > 0 else { break }
                items.append(LensItem(
                    id: node.path(of: file),
                    name: file.name,
                    size: file.allocatedSize,
                    content: .file(file),
                    color: file.kind.color
                ))
                nextFile = files.next()
            }
        }

        let shownSize = items.reduce(0) { $0 + $1.size }
        let rest = node.allocatedSize - shownSize
        let restCount = node.directories.count + node.files.count - items.count
        if rest > 0, restCount > 0 {
            items.append(LensItem(
                id: node.path + "/\u{0}others",
                name: "",
                size: rest,
                content: .others(count: restCount),
                color: .gray
            ))
        }
        return items
    }
}
