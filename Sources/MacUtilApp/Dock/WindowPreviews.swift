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
    let element: AXUIElement
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
        if window.minimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if let bundleID = app?.bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
        hide()
    }

    func close(_ window: PreviewWindow) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &value) == .success,
           let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
        windows.removeAll { $0.id == window.id }
        if windows.isEmpty { hide() }
    }

    func minimize(_ window: PreviewWindow) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        hide()
    }

    // MARK: - Finding and picturing the windows

    /// An app's standard windows with a picture of each, in the order macOS stacks them.
    private static func windows(of pid: pid_t) async -> [PreviewWindow] {
        let standard = standardWindows(of: pid)
        guard !standard.isEmpty else { return [] }
        guard canCapture,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else {
            return standard.enumerated().map { index, window in
                PreviewWindow(id: CGWindowID(index), title: window.title, image: nil, minimized: window.minimized, element: window.element)
            }
        }
        let shareable = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 60 && $0.frame.height > 40
        }
        var result: [PreviewWindow] = []
        var used = Set<CGWindowID>()
        for window in standard {
            // The same window to both: the nearest frame, the title to break a tie.
            let match = shareable
                .filter { !used.contains($0.windowID) }
                .min { distance($0, window) < distance($1, window) }
            guard let match, distance(match, window) < 40 || match.title == window.title else { continue }
            used.insert(match.windowID)
            let image = await picture(of: match)
            result.append(PreviewWindow(
                id: match.windowID, title: window.title.isEmpty ? (match.title ?? "") : window.title,
                image: image, minimized: window.minimized, element: window.element
            ))
        }
        return result
    }

    private static func distance(_ shared: SCWindow, _ window: StandardWindow) -> CGFloat {
        abs(shared.frame.minX - window.frame.minX) + abs(shared.frame.minY - window.frame.minY)
            + abs(shared.frame.width - window.frame.width) + abs(shared.frame.height - window.frame.height)
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

    private struct StandardWindow {
        let element: AXUIElement
        let title: String
        let frame: CGRect
        let minimized: Bool
    }

    /// The app's windows Accessibility calls standard, with their frames in screen points
    /// measured from the top, as ScreenCaptureKit measures them too.
    private static func standardWindows(of pid: pid_t) -> [StandardWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return [] }
        return list.compactMap { element in
            guard attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String else { return nil }
            var origin = CGPoint.zero
            var size = CGSize.zero
            if let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID() {
                AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            }
            if let extent = attribute(element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() {
                AXValueGetValue(extent as! AXValue, .cgSize, &size)
            }
            return StandardWindow(
                element: element,
                title: attribute(element, kAXTitleAttribute) as? String ?? "",
                frame: CGRect(origin: origin, size: size),
                minimized: attribute(element, kAXMinimizedAttribute) as? Bool ?? false
            )
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
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
