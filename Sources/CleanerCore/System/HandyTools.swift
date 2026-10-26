import AppKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake for as long as it is asked to.
///
/// macOS is told to hold off sleep rather than being tricked into staying busy, so the display
/// still dims and nothing is wasted.
public final class KeepAwake: @unchecked Sendable {
    public enum Scope: String, Sendable, CaseIterable, Identifiable {
        /// The Mac stays up but the screen may sleep.
        case system
        /// The screen stays on as well.
        case display

        public var id: String { rawValue }
    }

    public static let shared = KeepAwake()

    private var assertion: IOPMAssertionID = 0
    private let lock = NSLock()

    public private(set) var isOn = false
    /// When the hold ends by itself, if it was asked for a while.
    public private(set) var until: Date?

    private init() {}

    @discardableResult
    public func start(_ scope: Scope = .display, minutes: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()

        let type = scope == .display ? kIOPMAssertionTypeNoDisplaySleep : kIOPMAssertionTypeNoIdleSleep
        let reason = "UniMacHub keeps this Mac awake" as CFString
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &identifier)
        guard result == kIOReturnSuccess else { return false }

        assertion = identifier
        isOn = true
        until = minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) }
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    /// Ends the hold when its time is up. Called from the app's timer.
    public func expireIfDue(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let until, now >= until else { return }
        stopLocked()
    }

    private func stopLocked() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        isOn = false
        until = nil
    }
}

/// Small things people reach for often enough to deserve one click.
public enum QuickActions {
    /// Locks the screen, as the keyboard shortcut does.
    public static func lockScreen() async {
        _ = await Command.run("/usr/bin/pmset", ["displaysleepnow"], timeout: .seconds(10))
    }

    /// Ejects every disk that is not the one macOS runs from.
    @discardableResult
    public static func ejectRemovableDisks() async -> [String] {
        var ejected: [String] = []
        for disk in await DiskInventory.load() where !disk.isStartupDisk && (disk.isRemovable || disk.isDiskImage) {
            if await DiskOperations.eject(disk).succeeded { ejected.append(disk.model) }
        }
        return ejected
    }

    /// Hides or shows what sits on the desktop, for a clean screen while sharing it.
    public static func setDesktopIconsVisible(_ visible: Bool) async {
        _ = await Command.run(
            "/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", visible ? "true" : "false"],
            timeout: .seconds(15)
        )
        _ = await Command.run("/usr/bin/killall", ["Finder"], timeout: .seconds(15))
    }

    public static func desktopIconsAreVisible() async -> Bool {
        let output = await Command.run("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"], timeout: .seconds(10))
        // The setting is missing until someone changes it, and icons show by default.
        guard let text = output?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
        return text != "0" && text.lowercased() != "false"
    }

    /// Installs an app from a mounted disk image into the Applications folder, then puts the
    /// image away. The downloaded file is left alone unless `removeImage` says otherwise.
    public static func installApp(fromImage image: URL, removeImage: Bool = false) async -> DiskOperations.Outcome {
        let (outcome, attached) = await DiskImages.attach(image)
        guard outcome.succeeded, let mountPoint = attached?.mountPoint else { return outcome }
        defer { Task { _ = await DiskImages.detach(attached?.device ?? "", force: true) } }

        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? [])
            .filter { $0.hasSuffix(".app") }
        guard let app = apps.first else {
            return .refused(String(localized: "There is no app inside this disk image."))
        }
        let source = "\(mountPoint)/\(app)"
        let destination = "/Applications/\(app)"
        let copy = await Command.run("/usr/bin/ditto", [source, destination], timeout: .seconds(600))
        guard copy?.status == 0 else {
            return DiskOperations.Outcome(
                succeeded: false, output: copy?.text ?? "", wasCancelled: false, command: "ditto \(source) \(destination)"
            )
        }
        if removeImage { try? FileManager.default.trashItem(at: image, resultingItemURL: nil) }
        return DiskOperations.Outcome(
            succeeded: true, output: destination, wasCancelled: false, command: "ditto '\(source)' '\(destination)'"
        )
    }
}
