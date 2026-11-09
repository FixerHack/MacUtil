import AppKit
import CleanerCore
import Observation
import SwiftUI

/// The sizes that decide where the Dock sits within its window, shared by the view that draws
/// it and the controller that hands it the pointer, so the two always agree.
struct DockGeometry {
    let position: DockModel.Position
    let layout: DockLayout
    /// The window's length along the edge.
    let alongLength: CGFloat

    /// Between the screen's edge and the bar.
    static let margin: CGFloat = 4

    var icon: CGFloat { layout.icon }
    var vertical: Bool { position.isVertical }
    /// Between the bar's outer edge and the icons, where the running dots are.
    var edgeInset: CGFloat { Self.edgeInset(icon) }
    var thickness: CGFloat { Self.thickness(icon) }
    /// Where the unmagnified bar starts within the window.
    var offset: CGFloat { ((alongLength - layout.baseLength) / 2).rounded() }

    static func edgeInset(_ icon: CGFloat) -> CGFloat { max(8, icon * 0.13) }
    static func thickness(_ icon: CGFloat) -> CGFloat { edgeInset(icon) + icon + max(5, icon * 0.08) }

    /// A point in the window, from how far along the edge it is and how far from the edge.
    func point(along: CGFloat, depth: CGFloat, in size: CGSize) -> CGPoint {
        switch position {
        case .bottom: CGPoint(x: along, y: size.height - depth)
        case .left: CGPoint(x: depth, y: along)
        case .right: CGPoint(x: size.width - depth, y: along)
        }
    }

    /// How much room a label needs beside the icons.
    static func labelRoom(vertical: Bool) -> CGFloat { vertical ? 300 : 44 }
}

/// The window UniMacHub's Dock lives in, and the pointer that brings it out.
///
/// One borderless panel along an edge of the main screen, deep enough for the icons to grow
/// into and for their names. Only the Dock itself takes clicks: everywhere else in the panel
/// the pointer goes straight through to the windows behind, and while the Dock is hidden the
/// whole panel does.
@MainActor
final class DockController {
    private let model: DockModel
    private let sources: DockSources
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    /// While a menu from the Dock is open, it stays out.
    private var menuIsOpen = false

    init(model: DockModel, sources: DockSources) {
        self.model = model
        self.sources = sources
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.menuIsOpen = true }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.menuIsOpen = false
                self?.pointerMoved()
            }
        })
        follow()
        update()
    }

    private func follow() {
        withObservationTracking {
            _ = model.isEnabled
            _ = model.iconSize
            _ = model.magnifies
            _ = model.magnification
            _ = model.autohides
            _ = model.position
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.follow()
            }
        }
    }

    // MARK: - Placing it

    /// The screen with the menu bar.
    private var screen: NSScreen? { NSScreen.screens.first }

    private func panelFrame(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let icon = CGFloat(model.iconSize)
        let growth = model.magnifies ? icon * CGFloat(max(0, model.magnification - 1)) : 0
        let depth = DockGeometry.margin + DockGeometry.thickness(icon) + growth
            + DockGeometry.labelRoom(vertical: model.position.isVertical)
        switch model.position {
        case .bottom:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: depth.rounded(.up))
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: depth.rounded(.up), height: visible.maxY - frame.minY)
        case .right:
            return CGRect(x: frame.maxX - depth.rounded(.up), y: frame.minY, width: depth.rounded(.up), height: visible.maxY - frame.minY)
        }
    }

    func update() {
        guard model.isEnabled, let screen else {
            removeMonitors()
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        let frame = panelFrame(on: screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !model.autohides, !model.isShown { model.isShown = true }
        if model.autohides, model.isShown, model.pointer == nil { model.isShown = false }
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        installMonitors()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .dock
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        // Out of Mission Control, which brings up the system Dock in its place.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = DockHostingView(rootView: DockView(model: model, sources: sources))
        host.sizingOptions = []
        host.onPointer = { [weak self] in self?.pointerMoved() }
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: - The pointer

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// The pointer, as how far along the edge and how far from it, within the window.
    private func measure(_ point: NSPoint, in frame: CGRect) -> (along: CGFloat, depth: CGFloat) {
        switch model.position {
        case .bottom: (point.x - frame.minX, point.y - frame.minY)
        case .left: (frame.maxY - point.y, point.x - frame.minX)
        case .right: (frame.maxY - point.y, frame.maxX - point.x)
        }
    }

    private func pointerMoved() {
        guard let panel, model.isEnabled else { return }
        let frame = panel.frame
        let alongLength = model.position.isVertical ? frame.height : frame.width
        let entries = model.entries
        let available = alongLength - 24
        let base = model.layout(entries, available: available, pointer: nil)
        let now = model.layout(entries, available: available, pointer: model.pointer)
        let geometry = DockGeometry(position: model.position, layout: now, alongLength: alongLength)
        let (along, depth) = measure(NSEvent.mouseLocation, in: frame)
        let position = along - geometry.offset

        // The bar as it is drawn now, and above it the room the icons have grown into.
        let grown = model.pointer == nil ? 0 : (now.items.map { $0.scale }.max() ?? 1) - 1
        let reach = DockGeometry.margin + geometry.thickness + grown * geometry.icon
        let inside = model.isShown && depth <= reach
            && position >= min(now.barStart, 0) - 2 && position <= max(now.barEnd, base.baseLength) + 2

        if model.autohides {
            let atEdge = depth <= 1 && position >= -20 && position <= base.baseLength + 20
            if atEdge || inside || menuIsOpen {
                hideTask?.cancel()
                hideTask = nil
                if !model.isShown { model.isShown = true }
            } else if model.isShown, hideTask == nil {
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self else { return }
                    if !self.menuIsOpen { self.model.isShown = false }
                    self.hideTask = nil
                }
            }
        }

        // Clicks go through everywhere but the Dock itself.
        let takesClicks = inside || menuIsOpen
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }

        // Following the pointer at once; only arriving and leaving are eased.
        let pointer: CGFloat? = inside && !menuIsOpen ? position : (menuIsOpen ? model.pointer : nil)
        guard model.pointer != pointer else { return }
        if (model.pointer == nil) != (pointer == nil) {
            withAnimation(.easeOut(duration: 0.16)) { model.pointer = pointer }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.pointer = pointer }
        }
    }
}

/// Passes on every move of the pointer over the Dock, whether or not its window is key:
/// a window that never becomes key gets no moves otherwise.
final class DockHostingView: NSHostingView<DockView> {
    var onPointer: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?()
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onPointer?()
        return super.draggingUpdated(sender)
    }
}
