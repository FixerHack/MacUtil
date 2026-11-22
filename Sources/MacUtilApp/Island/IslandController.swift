import AppKit
import ApplicationServices
import CleanerCore
import Observation
import SwiftUI

/// The window the island lives in, where it sits, and the keys it listens to.
///
/// One borderless panel above the menu bar, on the screen with the notch if there is one.
/// It never takes focus from the app you are in, and it follows the island's state by
/// resizing around it rather than covering the top of the screen with an invisible window
/// that would swallow clicks meant for the menu bar.
@MainActor
final class IslandController {
    private let model: IslandModel
    private let state: AppState
    private var panel: NSPanel?
    /// The light along the top edge that stands in for a hidden island while the assistant works.
    private var glowPanel: NSPanel?
    /// While the island hides at rest: watches for the pointer at the top of the screen.
    private var edgeWatch: Task<Void, Never>?
    private var keyTap: MediaKeyTap?
    private var observers: [NSObjectProtocol] = []

    private var mouseMonitors: [Any] = []
    /// Counts resizes, so a shrink that was waiting gives way to a newer change.
    private var resizeGeneration = 0

    init(model: IslandModel, state: AppState) {
        self.model = model
        self.state = state
        model.openMain = { [weak state] in state?.showMain() }
        model.dock = state.dock
        model.assistant = state.assistant
        state.assistant.present = { [weak model] in model?.openAssistant() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
        watchClicksOutside()
        follow()
        update()
    }

    /// Keeps the panel in step with the model: whenever anything it reads changes, it reads again.
    private func follow() {
        withObservationTracking {
            _ = model.isEnabled
            _ = model.look
            _ = model.indicator
            _ = model.assistant?.phase
            _ = model.assistant?.isDictating
            _ = model.replacesIndicators
            _ = model.showsNowPlaying
            _ = model.presentation
            _ = model.calendar.isEnabled
            _ = state.islandWork
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.follow()
            }
        }
    }

    /// A click anywhere else closes the opened island, as it would close a menu.
    private func watchClicksOutside() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.clickedOutside() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.clickedOutside() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func clickedOutside() {
        // The island itself, not the window: the room left around it for the shadow counts
        // as outside.
        guard model.presentation == .expanded, let geometry = model.geometry else { return }
        let island = geometry.frame(for: .expanded)
            .insetBy(dx: -IslandGeometry.shoulder(for: .expanded), dy: 0)
        if !island.contains(NSEvent.mouseLocation) { model.close() }
    }

    // MARK: - Placing the panel

    /// The screen with a notch, else the main one.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func update() {
        // Only when it changed: every write tells the observers, and this method is one of
        // them, so writing the same value back would run it again and again for ever.
        let work = state.islandWork
        if model.work != work { model.work = work }
        updateKeyTap()
        model.setFeedRunning(model.isEnabled && model.showsNowPlaying)
        model.agents.setRunning(model.isEnabled)
        model.calendar.setRunning(model.isEnabled)
        guard model.isEnabled, let screen else { return hide() }
        let geometry = IslandGeometry(
            screen: screen.frame, topInset: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea
        )
        if model.geometry != geometry { model.geometry = geometry }
        // A hidden island: out of sight until the pointer reaches the top, or something opens it.
        let hides = model.hidesAtRest(hasNotch: geometry.hasNotch)
        watchEdge(hides ? geometry : nil)
        updateGlow(hides ? geometry : nil)
        // The volume and brightness it took from macOS still show, or nothing would.
        if hides, model.presentation != .expanded, model.indicator == nil { return hide() }

        let panel = self.panel ?? makePanel()
        let target = geometry.panelFrame(for: model.presentation)
        resizeGeneration += 1
        let generation = resizeGeneration
        if panel.frame != target {
            // The island draws itself at its own size inside the window and springs from one
            // size to the next. The window grows at once, so there is room for that, and
            // shrinks only once the island has finished folding in.
            let fits = target.width >= panel.frame.width && target.height >= panel.frame.height
            if fits || !panel.isVisible {
                panel.setFrame(target, display: true)
            } else {
                panel.setFrame(target.union(panel.frame), display: true)
                Task { @MainActor [weak self, weak panel] in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard let self, let panel, generation == self.resizeGeneration else { return }
                    panel.setFrame(target, display: true)
                }
            }
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        if !model.isEnabled { updateGlow(nil) }
    }

    /// The assistant at work, or UniMacHub busy, while the island hides: a light along the top
    /// edge instead.
    private var wantsGlow: Bool {
        if model.work != nil { return true }
        guard let assistant = model.assistant else { return false }
        return assistant.phase != .idle || assistant.isDictating
    }

    private func updateGlow(_ geometry: IslandGeometry?) {
        guard let geometry, wantsGlow, model.presentation != .expanded else {
            glowPanel?.orderOut(nil)
            return
        }
        let panel = glowPanel ?? makeGlowPanel()
        let width: CGFloat = 520, height: CGFloat = 46
        let frame = CGRect(x: geometry.resting.midX - width / 2, y: geometry.screen.maxY - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    private func makeGlowPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TopEdgeGlow(model: model))
        glowPanel = panel
        return panel
    }

    /// Ten times a second while the island hides: the pointer at the very top, over where the
    /// island would be, brings it out; once it has left the opened island, the island goes.
    private func watchEdge(_ geometry: IslandGeometry?) {
        guard let geometry else {
            edgeWatch?.cancel()
            edgeWatch = nil
            return
        }
        guard edgeWatch == nil else { return }
        edgeWatch = Task { [weak self] in
            var outsideSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let geometry = self.model.geometry else { continue }
                let pointer = NSEvent.mouseLocation
                let zone = geometry.resting.insetBy(dx: -90, dy: 0)
                let atTop = pointer.y >= geometry.screen.maxY - 2 && pointer.x >= zone.minX && pointer.x <= zone.maxX
                if atTop, !self.model.isHovering {
                    self.model.revealFromEdge()
                    outsideSince = nil
                } else if self.model.isHovering, let panel = self.panel, panel.isVisible {
                    // The pointer may never have "entered" a window that appeared under it.
                    if panel.frame.contains(pointer) {
                        outsideSince = nil
                    } else if let since = outsideSince {
                        if Date().timeIntervalSince(since) > 0.4 { self.model.isHovering = false }
                    } else {
                        outsideSince = Date()
                    }
                }
            }
        }
        _ = geometry
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableIslandPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        // Above the menu bar, which sits at the main menu level.
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The island draws its own soft shadow; the window's would be a hard rectangle.
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // Every desktop, and hidden while Mission Control is open: it sits right over the row
        // of desktops there and would be in the way of picking one.
        // Over full-screen apps too: the island is the same there, by the same look.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = IslandHostingView(rootView: IslandView(model: model, state: state), model: model)
        // The window follows the island's state, never the other way round.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: - Keys

    private func updateKeyTap() {
        let wanted = model.isEnabled && model.replacesIndicators && AXIsProcessTrusted()
        if wanted, keyTap == nil {
            keyTap = MediaKeyTap { [weak self] press in
                self?.model.handle(press) ?? false
            }
        } else if !wanted, keyTap != nil {
            keyTap = nil
        }
    }
}

/// The hosting view, with hover tracked by AppKit itself.
///
/// The panel never becomes key and the app is usually in the background, where SwiftUI's
/// own hover does not always fire; a tracking area that is active always does.
final class IslandHostingView: NSHostingView<IslandView> {
    private let model: IslandModel

    init(rootView: IslandView, model: IslandModel) {
        self.model = model
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: IslandView) { fatalError("init(rootView:) is not used") }

    @available(*, unavailable)
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { model.isHovering = true }
    override func mouseExited(with event: NSEvent) { model.isHovering = false }

    /// The first click works even though the app is not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Listens to the volume, brightness and media keys before macOS acts on them.
///
/// An event tap that may swallow a key needs Accessibility. Whatever the handler does not
/// take goes on to macOS unchanged, so a key the island cannot do anything with still works.
final class MediaKeyTap {
    typealias Handler = @MainActor (MediaKeyPress) -> Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate let handler: Handler

    @MainActor
    init?(handler: @escaping Handler) {
        self.handler = handler
        // NX_SYSDEFINED: the event type special keys arrive as.
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            // macOS switches a slow tap off; switch it back on.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.tap { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type.rawValue == 14, let system = NSEvent(cgEvent: event),
                  let press = MediaKeyPress(subtype: Int(system.subtype.rawValue), data1: system.data1)
            else { return Unmanaged.passUnretained(event) }
            // The tap runs on the main run loop, so this is the main actor.
            let taken = MainActor.assumeIsolated { tap.handler(press) }
            return taken ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

/// A borderless panel never takes the keyboard on its own; this one may, only when the
/// assistant's field asks, and without bringing UniMacHub to the front.
final class KeyableIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The hidden island's stand-in while the assistant listens or works: light pooling down from
/// the top edge, turning slowly, brighter with the voice.
struct TopEdgeGlow: View {
    let model: IslandModel

    private static let colours: [Color] = [
        Color(red: 0.55, green: 0.35, blue: 1), Color(red: 0.2, green: 0.6, blue: 1),
        Color(red: 0.25, green: 0.95, blue: 0.85), Color(red: 1, green: 0.45, blue: 0.7),
        Color(red: 0.55, green: 0.35, blue: 1),
    ]

    var body: some View {
        let level = model.assistant.map { $0.phase == .listening || $0.isDictating ? $0.level : 0.35 } ?? 0.35
        // Thirty frames a second, drawn by the graphics chip: drawn by the processor at the
        // screen's full rate, the turning colours took half of it.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
            Capsule()
                .fill(AngularGradient(colors: Self.colours, center: .center, angle: .degrees(turn)))
                .frame(height: 10 + 18 * level)
                .offset(y: -8)
                .blur(radius: 10 + 6 * level)
                .opacity(0.9)
                .frame(maxHeight: .infinity, alignment: .top)
                .drawingGroup()
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .allowsHitTesting(false)
    }
}
