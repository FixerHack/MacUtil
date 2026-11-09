import AppKit
import ApplicationServices
import Observation

/// One window sent to the Dock with the yellow button.
struct MinimizedWindow: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let title: String
    let appName: String
    let appURL: URL?
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }
}

/// The windows minimised in every app, read and brought back through Accessibility.
///
/// The system Dock is where macOS puts them; with it hidden they would be out of reach. Apps
/// tell Accessibility when one of their windows is minimised or brought back, so this
/// listens to each app and, to catch a window closed while minimised, looks again every few
/// seconds. It needs Accessibility permission for the Dock's process; without it the list
/// stays empty and the settings page explains how to allow it.
@MainActor
@Observable
final class MinimizedWindows {
    private(set) var windows: [MinimizedWindow] = []
    private(set) var isTrusted = AXIsProcessTrusted()
    /// Told when the list or the permission changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers = [:]
        if !windows.isEmpty {
            windows = []
            onChange?()
        }
    }

    /// Shows macOS's own request for the permission, which leads to System Settings.
    func askForPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        onChange?()
    }

    /// Soon, once: an app often reports several changes in a row.
    func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            onChange?()
        }
        guard trusted else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        var found: [MinimizedWindow] = []
        var alive = Set<pid_t>()
        for app in apps {
            let pid = app.processIdentifier
            alive.insert(pid)
            let element = AXUIElementCreateApplication(pid)
            // An app that hangs must not hang the Dock.
            AXUIElementSetMessagingTimeout(element, 0.25)
            watch(pid, element)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement]
            else { continue }
            for window in list where Self.bool(window, kAXMinimizedAttribute) {
                let title = Self.string(window, kAXTitleAttribute) ?? ""
                found.append(MinimizedWindow(
                    id: "\(pid).\(CFHash(window))",
                    pid: pid,
                    title: title,
                    appName: app.localizedName ?? "",
                    appURL: app.bundleURL,
                    element: window
                ))
            }
        }
        for pid in observers.keys where !alive.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        // Kept in the order they were minimised: new ones go at the end.
        let kept = windows.filter { old in found.contains { $0.id == old.id } }
            .map { old in found.first { $0.id == old.id } ?? old }
        let added = found.filter { new in !kept.contains { $0.id == new.id } }
        let result = kept + added
        if result != windows {
            windows = result
            onChange?()
        }
    }

    /// Brings a window back, and its app forward.
    func restore(_ window: MinimizedWindow) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        scheduleRefresh()
    }

    /// Closes it with its own close button, as a click on it would.
    func close(_ window: MinimizedWindow) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &value) == .success,
           let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
        scheduleRefresh()
    }

    // MARK: - Listening to each app

    private func watch(_ pid: pid_t, _ app: AXUIElement) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<MinimizedWindows>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.scheduleRefresh() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
