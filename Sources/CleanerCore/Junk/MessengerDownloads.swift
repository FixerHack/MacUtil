import Foundation

/// A file a messaging app saved on your Mac, which it will happily download again.
public struct MessengerFile: Sendable, Identifiable, Hashable {
    public let path: String
    public let app: String
    public let name: String
    public let size: Int64
    public let modified: Date?

    public var id: String { path }

    public func age(from now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(modified ?? now)
    }
}

/// Finds what messaging apps keep downloading and never clear.
///
/// Telegram, WhatsApp and the rest save every picture, video and document you open, and keep
/// them for good. Nothing here is unique: anything removed can be downloaded again from the chat.
public enum MessengerDownloads {
    /// Where each app keeps what it downloaded, relative to the home folder.
    static let places: [(app: String, path: String)] = [
        ("Telegram", "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-*/postbox/media"),
        ("Telegram", "Downloads/Telegram Desktop"),
        ("Telegram", "Library/Application Support/Telegram Desktop/tdata/user_data/cache"),
        ("WhatsApp", "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"),
        ("Viber", "Library/Application Support/ViberPC"),
        ("Signal", "Library/Application Support/Signal/attachments.noindex"),
        ("Discord", "Library/Application Support/discord/Cache"),
        ("Slack", "Library/Application Support/Slack/Service Worker/CacheStorage"),
    ]

    /// Everything older than `olderThan`, newest first. Zero keeps everything.
    public static func scan(
        olderThan: TimeInterval = 0, now: Date = Date(), protected: ProtectedPaths = .current()
    ) async -> [MessengerFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files: [MessengerFile] = []
        for place in places {
            for root in expand(home.appending(path: place.path).path) {
                files += await contents(of: root, app: place.app, olderThan: olderThan, now: now)
            }
        }
        return files.filter { !protected.covers($0.path) }.sorted { $0.size > $1.size }
    }

    /// Resolves one `*` in a path, which is how accounts are kept apart.
    static func expand(_ path: String) -> [String] {
        guard let star = path.firstIndex(of: "*") else {
            return FileManager.default.fileExists(atPath: path) ? [path] : []
        }
        let parent = String(path[path.startIndex ..< star])
        let directory = (parent as NSString).deletingLastPathComponent
        let prefix = (parent as NSString).lastPathComponent
        let suffix = String(path[path.index(after: star)...])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .map { "\(directory)/\($0)\(suffix)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func contents(
        of root: String, app: String, olderThan: TimeInterval, now: Date
    ) async -> [MessengerFile] {
        await Task.detached {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let walker = FileManager.default.enumerator(
                at: URL(filePath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { return [] }

            var found: [MessengerFile] = []
            // allObjects rather than a loop over the enumerator, which Swift will not iterate here.
            for case let url as URL in walker.allObjects {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                let modified = values.contentModificationDate
                let age = now.timeIntervalSince(modified ?? now)
                guard olderThan <= 0 || age >= olderThan else { continue }
                found.append(MessengerFile(
                    path: url.path, app: app, name: url.lastPathComponent,
                    size: Int64(values.totalFileAllocatedSize ?? 0), modified: modified
                ))
                if found.count >= 20000 { break }
            }
            return found
        }.value
    }
}
