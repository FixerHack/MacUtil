import CleanerCore
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

    init() {
        refresh()
    }

    func refresh() {
        fullDiskAccess = FullDiskAccess.status()
        startupDisk = try? VolumeInfo.forVolume()
    }
}
