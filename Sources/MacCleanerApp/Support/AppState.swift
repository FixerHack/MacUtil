import CleanerCore
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selection: Module? = .dashboard
    let scans = ScanStore()
    let systemJunk = JunkStore(group: .system)
    let developerJunk = JunkStore(group: .developer)
    let trash = TrashStore()
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown
    private(set) var startupDisk: VolumeInfo?
    /// The Full Disk Access guide; opens on launch while access is missing.
    var showsPermissionsGuide = false

    init() {
        refresh()
        showsPermissionsGuide = fullDiskAccess != .granted
            && ProcessInfo.processInfo.environment["MACCLEANER_SNAPSHOT"] == nil
    }

    func refresh() {
        fullDiskAccess = FullDiskAccess.status()
        startupDisk = try? VolumeInfo.forVolume()
    }
}
