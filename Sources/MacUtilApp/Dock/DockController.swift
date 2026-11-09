import AppKit
import CleanerCore
import Observation
import SwiftUI

/// The window UniMacHub's Dock lives in, and the pointer that brings it out.
///
/// One borderless panel along an edge of the main screen, wide enough for the icons to grow
/// into. Only the Dock itself takes clicks: everywhere else in the panel the pointer goes
/// straight through to the windows behind, and while the Dock is hidden the whole panel does.
@MainActor
final class DockController {
    private let model: DockModel
    private let state: AppState
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?

    /// Room between the icons and the edge of the bar, and for the running dots.
    static let padding: CGFloat = 10
    static let indicator: CGFloat = 8

    init(model: DockModel, state: AppState) {
        self.model = model
        self.state = state
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.quitting() }
        })
        model.launched()
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

    /// How thick the bar is, and how much more the icons need when they grow.
    private var thickness: CGFloat { CGFloat(model.iconSize) + 2 * Self.padding + Self.indicator }
    private var growth: CGFloat {
        model.magnifies ? CGFloat(model.iconSize) * CGFloat(max(0, model.magnification - 1)) : 0
    }

    private func panelFrame(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let depth = thickness + growth + 8
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: DockView(model: model, state: state))
        host.sizingOptions = []
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

    /// The part of the panel the Dock takes up now: the bar, and above it the room the
    /// icons grow into while the pointer is on them.
    private func dockRect(in panel: CGRect) -> CGRect {
        let length = model.barLength + (model.pointer == nil ? 0 : CGFloat(model.iconSize))
        let depth = thickness + (model.pointer == nil ? 0 : growth)
        switch model.position {
        case .bottom:
            return CGRect(x: panel.midX - length / 2, y: panel.minY, width: length, height: depth)
        case .left:
            return CGRect(x: panel.minX, y: panel.midY - length / 2, width: depth, height: length)
        case .right:
            return CGRect(x: panel.maxX - depth, y: panel.midY - length / 2, width: depth, height: length)
        }
    }

    /// At the very edge of the screen, where the Dock comes out from.
    private func isAtEdge(_ point: NSPoint, panel: CGRect) -> Bool {
        let span = model.barLength
        switch model.position {
        case .bottom: return point.y <= panel.minY + 2 && abs(point.x - panel.midX) < span / 2 + 40
        case .left: return point.x <= panel.minX + 2 && abs(point.y - panel.midY) < span / 2 + 40
        case .right: return point.x >= panel.maxX - 2 && abs(point.y - panel.midY) < span / 2 + 40
        }
    }

    private func pointerMoved() {
        guard let panel, model.isEnabled else { return }
        let point = NSEvent.mouseLocation
        let frame = panel.frame
        let inside = model.isShown && dockRect(in: frame).contains(point)

        if model.autohides {
            if isAtEdge(point, panel: frame) || inside {
                hideTask?.cancel()
                hideTask = nil
                if !model.isShown { model.isShown = true }
            } else if model.isShown, hideTask == nil {
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self else { return }
                    self.model.isShown = false
                    self.hideTask = nil
                }
            }
        }

        // Clicks go through everywhere but the Dock itself.
        let takesClicks = model.isShown && dockRect(in: frame).contains(point)
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }

        // Along the Dock, measured from its middle, for the magnification.
        let along: CGFloat? = takesClicks ? (model.position.isVertical ? frame.midY - point.y : point.x - frame.midX) : nil
        if model.pointer != along { model.pointer = along }
    }
}
