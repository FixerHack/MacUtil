import AppKit
import ApplicationServices
import Observation
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// One of an app's windows, as the preview over the Dock shows it.
struct PreviewWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let image: NSImage?
    let minimized: Bool
    /// Nil when Accessibility could not reach it: a click then brings its app forward.
    let element: AXUIElement?
}

/// The previews of an app's windows that come up over the Dock while the pointer rests on it.
///
/// Pictures come from ScreenCaptureKit, which needs Screen Recording for the Dock's process;
/// which window is which, and bringing one forward, closing or minimising it, come from
/// Accessibility. Only an app's standard windows are shown: those Accessibility knows as
/// such, which leaves out palettes, menus and the like.
@MainActor
@Observable
final class WindowPreviews {
    private(set) var app: DockModel.App?
    private(set) var windows: [PreviewWindow] = []
    private(set) var isLoading = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored let model: DockModel

    init(model: DockModel) {
        self.model = model
    }

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    var isVisible: Bool { panel?.isVisible == true }

    /// Whether the pointer is over the previews, which keeps them and the Dock out.
    func contains(_ point: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    /// Shows an app's windows next to its icon, given the icon's place on screen.
    func show(_ app: DockModel.App, from icon: CGRect, edge: DockModel.Position) {
        guard app.id != self.app?.id || !isVisible else { return }
        self.app = app
        windows = []
        isLoading = true
        place(near: icon, edge: edge, count: 1)
        loading?.cancel()
        loading = Task { [weak self] in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").first?.processIdentifier
            else { return }
            let found = await Self.windows(of: pid)
            guard !Task.isCancelled, let self, self.app?.id == app.id else { return }
            self.isLoading = false
            self.windows = found
            if found.isEmpty {
                self.hide()
            } else {
                self.place(near: icon, edge: edge, count: found.count)
            }
        }
    }

    func hide() {
        loading?.cancel()
        panel?.orderOut(nil)
        app = nil
        windows = []
    }

    // MARK: - The window it lives in

    static let card = CGSize(width: 220, height: 150)
    static let spacing: CGFloat = 10

    private func place(near icon: CGRect, edge: DockModel.Position, count: Int) {
        let panel = self.panel ?? makePanel()
        let vertical = edge.isVertical
        let cards = CGFloat(max(1, min(count, 6)))
        let size = vertical
            ? CGSize(width: Self.card.width + 24, height: cards * (Self.card.height + 30) + (cards - 1) * Self.spacing + 24)
            : CGSize(width: cards * Self.card.width + (cards - 1) * Self.spacing + 24, height: Self.card.height + 30 + 24)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + 8)
        case .left: origin = CGPoint(x: icon.maxX + 8, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - 8 - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.dock.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: WindowPreviewView(previews: self))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: - Acting on a window

    func focus(_ window: PreviewWindow) {
        if let element = window.element {
            if window.minimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if let bundleID = app?.bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
        hide()
    }

    func close(_ window: PreviewWindow) {
        var value: CFTypeRef?
        if let element = window.element,
           AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
           let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
        windows.removeAll { $0.id == window.id }
        if windows.isEmpty { hide() }
    }

    func minimize(_ window: PreviewWindow) {
        guard let element = window.element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        hide()
    }

    // MARK: - Finding and picturing the windows

    /// An app's windows with a picture of each, on every desktop and full-screen space.
    ///
    /// ScreenCaptureKit lists them all; Accessibility only sees the current desktop's unless
    /// asked for each window by number, which is how AltTab and DockDoor reach the rest.
    private static func windows(of pid: pid_t) async -> [PreviewWindow] {
        let content = canCapture
            ? try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            : nil
        let wanted = Set((content?.windows ?? [])
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 80 }
            .map(\.windowID))
        let reachable = await Task.detached { AXWindows.byNumber(of: pid, wanting: wanted) }.value
        guard let content else {
            // No pictures: the windows Accessibility knows, by name.
            return reachable.values.filter(\.isStandard).sorted { $0.title < $1.title }.map {
                PreviewWindow(id: $0.number, title: $0.title, image: nil, minimized: $0.minimized, element: $0.element)
            }
        }
        var result: [PreviewWindow] = []
        for window in content.windows where window.owningApplication?.processID == pid && window.windowLayer == 0 {
            let known = reachable[window.windowID]
            if let known {
                guard known.isStandard else { continue }
            } else {
                // Out of Accessibility's reach: only what looks like a real window.
                guard window.frame.width >= 200, window.frame.height >= 150, !(window.title ?? "").isEmpty else { continue }
            }
            let image = await picture(of: window)
            let title = known?.title.isEmpty == false ? known!.title : (window.title ?? "")
            result.append(PreviewWindow(
                id: window.windowID, title: title, image: image,
                minimized: known?.minimized ?? false, element: known?.element
            ))
        }
        return result
    }

    private static func picture(of window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(1, 2 * card.width / max(window.frame.width, 1))
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// An app's windows through Accessibility, keyed by their window number.
enum AXWindows {
    struct Window: @unchecked Sendable {
        let element: AXUIElement
        let number: CGWindowID
        let title: String
        let minimized: Bool
        let isStandard: Bool
    }

    // Not in the public headers, but stable for years and used by AltTab, DockDoor and
    // others; looked up at run time so a macOS without them only loses other desktops.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    nonisolated(unsafe) private static let handle = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW
    )
    nonisolated(unsafe) private static let getWindow: GetWindow? = dlsym(handle, "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }
    nonisolated(unsafe) private static let createWithToken: CreateWithToken? = dlsym(handle, "_AXUIElementCreateWithRemoteToken")
        .map { unsafeBitCast($0, to: CreateWithToken.self) }

    /// - Parameter wanted: the windows to look for beyond the current desktop; the search
    ///   stops once they are all found.
    static func byNumber(of pid: pid_t, wanting wanted: Set<CGWindowID>) -> [CGWindowID: Window] {
        guard let getWindow else { return [:] }
        var found: [CGWindowID: Window] = [:]
        func add(_ element: AXUIElement) {
            var number: CGWindowID = 0
            guard getWindow(element, &number) == .success, number != 0, found[number] == nil,
                  string(element, kAXRoleAttribute) == kAXWindowRole as String
            else { return }
            let subrole = string(element, kAXSubroleAttribute)
            found[number] = Window(
                element: element, number: number,
                title: string(element, kAXTitleAttribute) ?? "",
                minimized: bool(element, kAXMinimizedAttribute),
                isStandard: subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String
            )
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        // An app that does not answer is not asked a thousand times more.
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return found }
        list.forEach(add)
        // The rest, on other desktops: each element the app has, asked for by its number.
        if let createWithToken, !wanted.isSubset(of: Set(found.keys)) {
            for id in UInt64(0) ..< 1000 where !wanted.isSubset(of: Set(found.keys)) {
                var token = Data(count: 20)
                token.withUnsafeMutableBytes { bytes in
                    bytes.storeBytes(of: Int32(pid), toByteOffset: 0, as: Int32.self)
                    bytes.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
                    bytes.storeBytes(of: Int32(0x636F_636F), toByteOffset: 8, as: Int32.self)
                    bytes.storeBytes(of: id, toByteOffset: 12, as: UInt64.self)
                }
                guard let element = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
                AXUIElementSetMessagingTimeout(element, 0.1)
                add(element)
            }
        }
        return found
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }
}

/// The cards over the Dock: a picture of each window and its title, with close and minimise.
private struct WindowPreviewView: View {
    let previews: WindowPreviews

    var body: some View {
        let layout = previews.model.position.isVertical
            ? AnyLayout(VStackLayout(spacing: WindowPreviews.spacing))
            : AnyLayout(HStackLayout(spacing: WindowPreviews.spacing))
        Group {
            if previews.windows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                layout {
                    ForEach(previews.windows.prefix(6)) { window in
                        PreviewCard(window: window, previews: previews)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

private struct PreviewCard: View {
    let window: PreviewWindow
    let previews: WindowPreviews
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: window.title.isEmpty ? (previews.app?.name ?? "") : window.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hovered {
                    Button { previews.minimize(window) } label: { Image(systemName: "minus.circle.fill") }
                        .help(Text("Minimise"))
                    Button { previews.close(window) } label: { Image(systemName: "xmark.circle.fill") }
                        .help(Text("Close Window"))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            Group {
                if let image = window.image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: window.minimized ? "minus.rectangle" : "macwindow")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: WindowPreviews.card.width, height: WindowPreviews.card.height)
            .opacity(window.minimized ? 0.6 : 1)
        }
        .padding(4)
        .background(.white.opacity(hovered ? 0.1 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .onTapGesture { previews.focus(window) }
    }
}
