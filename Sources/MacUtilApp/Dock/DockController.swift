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

/// What one screen's Dock is doing: out or hidden, where the pointer is, which folder is open.
@MainActor
@Observable
final class DockPanelState {
    /// Whether the Dock is out, when it hides itself.
    var isShown = false
    /// Where the pointer is along the unmagnified bar; nil when it is not on this Dock.
    var pointer: CGFloat?
    /// The folder whose contents are open over this Dock.
    var openFolder: URL?
    /// A widget with its own panel open over this Dock, such as the calculator.
    var openWidget: DockModel.Widget?
    var holdsOpen: Bool { openFolder != nil || openWidget != nil }
}

/// The windows UniMacHub's Dock lives in, one per screen it is on, and the pointer that
/// brings each out.
///
/// Each is a borderless panel along an edge, deep enough for the icons to grow into and for
/// their names. Only the Dock itself takes clicks: everywhere else in the panel the pointer
/// goes straight through to the windows behind, and while the Dock is hidden the whole panel
/// does.
@MainActor
final class DockController {
    /// One screen's Dock.
    private final class ScreenDock {
        let screenID: String
        let panel: NSPanel
        let state: DockPanelState
        var hideTask: Task<Void, Never>?

        init(screenID: String, panel: NSPanel, state: DockPanelState) {
            self.screenID = screenID
            self.panel = panel
            self.state = state
        }
    }

    private let model: DockModel
    private let sources: DockSources
    private var docks: [String: ScreenDock] = [:]
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// While a menu from the Dock is open, it stays out.
    private var menuIsOpen = false
    private var previewTask: Task<Void, Never>?
    private var previewWanted: String?

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
            _ = model.displays
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.follow()
            }
        }
    }

    // MARK: - Placing them

    private func panelFrame(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let icon = CGFloat(model.iconSize)
        let growth = model.magnifies ? icon * CGFloat(max(0, model.magnification - 1)) : 0
        let depth = (DockGeometry.margin + DockGeometry.thickness(icon) + growth
            + DockGeometry.labelRoom(vertical: model.position.isVertical)).rounded(.up)
        switch model.position {
        case .bottom:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: depth)
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: depth, height: visible.maxY - frame.minY)
        case .right:
            return CGRect(x: frame.maxX - depth, y: frame.minY, width: depth, height: visible.maxY - frame.minY)
        }
    }

    func update() {
        let wanted: [(String, NSScreen)] = model.isEnabled
            ? NSScreen.screens.enumerated().compactMap { index, screen in
                let id = DockModel.displayID(of: screen)
                return model.shows(onDisplay: id, isMain: index == 0) ? (id, screen) : nil
            }
            : []
        let keep = Set(wanted.map(\.0))
        for (id, dock) in docks where !keep.contains(id) {
            dock.hideTask?.cancel()
            dock.panel.orderOut(nil)
            docks[id] = nil
        }
        guard !wanted.isEmpty else {
            removeMonitors()
            return
        }
        for (id, screen) in wanted {
            let dock = docks[id] ?? makeDock(id)
            docks[id] = dock
            let frame = panelFrame(on: screen)
            if dock.panel.frame != frame { dock.panel.setFrame(frame, display: true) }
            if !model.autohides, !dock.state.isShown { dock.state.isShown = true }
            if model.autohides, dock.state.isShown, dock.state.pointer == nil { dock.state.isShown = false }
            dock.panel.ignoresMouseEvents = true
            dock.panel.orderFrontRegardless()
        }
        installMonitors()
    }

    private func makeDock(_ id: String) -> ScreenDock {
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
        let state = DockPanelState()
        let host = DockHostingView(rootView: DockView(model: model, sources: sources, state: state))
        host.sizingOptions = []
        host.onPointer = { [weak self] in self?.pointerMoved() }
        panel.contentView = host
        return ScreenDock(screenID: id, panel: panel, state: state)
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
        // A click in another app closes an open folder: its popover cannot tell, as this
        // process is never the active one.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for dock in self.docks.values where dock.state.holdsOpen {
                    dock.state.openFolder = nil
                    dock.state.openWidget = nil
                }
                self.pointerMoved()
            }
        }) {
            monitors.append(clicks)
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

    /// The pointer, as how far along the edge and how far from it, within a window.
    private func measure(_ point: NSPoint, in frame: CGRect) -> (along: CGFloat, depth: CGFloat) {
        switch model.position {
        case .bottom: (point.x - frame.minX, point.y - frame.minY)
        case .left: (frame.maxY - point.y, point.x - frame.minX)
        case .right: (frame.maxY - point.y, frame.maxX - point.x)
        }
    }

    private func pointerMoved() {
        guard model.isEnabled else { return }
        let point = NSEvent.mouseLocation
        let entries = model.entries
        for dock in docks.values {
            pointerMoved(point, entries: entries, on: dock)
        }
    }

    private func pointerMoved(_ point: NSPoint, entries: [DockModel.Entry], on dock: ScreenDock) {
        let state = dock.state
        let panel = dock.panel
        let frame = panel.frame
        // A menu, an open folder or the window previews keep the Dock out.
        let overPreviews = sources.previews.contains(point)
        let holding = (menuIsOpen && state.pointer != nil) || state.holdsOpen || overPreviews
        let alongLength = model.position.isVertical ? frame.height : frame.width
        let available = alongLength - 24
        let base = model.layout(entries, available: available, pointer: nil)
        let now = model.layout(entries, available: available, pointer: state.pointer)
        let geometry = DockGeometry(position: model.position, layout: now, alongLength: alongLength)
        let (along, depth) = measure(point, in: frame)
        let onScreen = frame.insetBy(dx: -1, dy: -1).contains(point) || {
            // Beyond the window along the edge it is another screen; past its depth it is this one.
            switch model.position {
            case .bottom: return point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY
            case .left, .right: return point.y >= frame.minY && point.y < frame.maxY
            }
        }()
        let position = along - geometry.offset

        // The bar as it is drawn now, and above it the room the icons have grown into.
        let grown = state.pointer == nil ? 0 : (now.items.map(\.scale).max() ?? 1) - 1
        let reach = DockGeometry.margin + geometry.thickness + grown * geometry.icon
        let inside = onScreen && state.isShown && depth >= -1 && depth <= reach
            && position >= min(now.barStart, 0) - 2 && position <= max(now.barEnd, base.baseLength) + 2

        if model.autohides {
            let atEdge = onScreen && depth >= -1 && depth <= 1 && position >= -20 && position <= base.baseLength + 20
            if atEdge || inside || holding {
                dock.hideTask?.cancel()
                dock.hideTask = nil
                if !state.isShown { setShown(true, state) }
            } else if state.isShown, dock.hideTask == nil {
                dock.hideTask = Task { [weak self, weak dock] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self, let dock else { return }
                    if !(self.menuIsOpen && dock.state.pointer != nil), !dock.state.holdsOpen {
                        self.setShown(false, dock.state)
                    }
                    dock.hideTask = nil
                }
            }
        }

        previews(inside ? now.hovered : nil, entries, geometry, frame: frame, overPreviews: overPreviews, onScreen: onScreen)

        // Clicks go through everywhere but the Dock itself.
        let takesClicks = inside || (holding && !overPreviews)
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }

        // Following the pointer at once; only arriving and leaving are eased.
        let pointer: CGFloat? = holding ? state.pointer : (inside ? position : nil)
        guard state.pointer != pointer else { return }
        if (state.pointer == nil) != (pointer == nil) {
            withAnimation(.easeOut(duration: 0.16)) { state.pointer = pointer }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.pointer = pointer }
        }
    }

    /// The previews of a running app's windows, once the pointer has rested on it a moment,
    /// and at once when it moves to the next app while they are up.
    private func previews(
        _ hovered: Int?, _ entries: [DockModel.Entry], _ geometry: DockGeometry,
        frame: CGRect, overPreviews: Bool, onScreen: Bool
    ) {
        guard onScreen else { return }
        let previews = sources.previews
        guard model.showsPreviews, model.accessibilityGranted else {
            if previews.isVisible { previews.hide() }
            return
        }
        if overPreviews { previewTask?.cancel(); previewWanted = previews.app?.id; return }
        guard let hovered, case let .app(app) = entries[hovered], app.isRunning,
              menuIsOpen == false
        else {
            previewWanted = nil
            previewTask?.cancel()
            if previews.isVisible {
                previewTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.previewWanted == nil else { return }
                    self.sources.previews.hide()
                }
            }
            return
        }
        guard previewWanted != app.id else { return }
        previewWanted = app.id
        previewTask?.cancel()
        let item = geometry.layout.items[hovered]
        let icon = tileRect(item, geometry, frame: frame)
        let edge = model.position
        if previews.isVisible {
            previews.show(app, from: icon, edge: edge)
            return
        }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.previewWanted == app.id else { return }
            self.sources.previews.show(app, from: icon, edge: edge)
        }
    }

    /// An icon's place on screen.
    private func tileRect(_ item: DockLayout.Placed, _ geometry: DockGeometry, frame: CGRect) -> CGRect {
        let side = geometry.icon * item.scale
        let along = geometry.offset + item.centre
        let near = DockGeometry.margin + geometry.edgeInset
        switch model.position {
        case .bottom: return CGRect(x: frame.minX + along - side / 2, y: frame.minY + near, width: side, height: side)
        case .left: return CGRect(x: frame.minX + near, y: frame.maxY - along - side / 2, width: side, height: side)
        case .right: return CGRect(x: frame.maxX - near - side, y: frame.maxY - along - side / 2, width: side, height: side)
        }
    }

    /// Slides a Dock out with a soft spring, and back in without one, as the system Dock does.
    private func setShown(_ shown: Bool, _ state: DockPanelState) {
        let animation: Animation = shown
            ? .spring(response: 0.5, dampingFraction: 0.86)
            : .timingCurve(0.4, 0, 0.6, 1, duration: 0.32)
        withAnimation(animation) { state.isShown = shown }
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
