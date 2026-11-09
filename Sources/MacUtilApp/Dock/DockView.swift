import AppKit
import CleanerCore
import CoreWLAN
import SwiftUI

/// One place along the Dock.
private enum DockEntry: Identifiable {
    case widget(DockModel.Widget)
    case app(DockModel.App)
    case tools(SidebarSection)
    case divider(Int)
    case trash

    var id: String {
        switch self {
        case let .widget(widget): "widget." + widget.rawValue
        case let .app(app): "app." + app.id
        case let .tools(section): "tools.\(section)"
        case let .divider(index): "divider.\(index)"
        case .trash: "trash"
        }
    }

    var grows: Bool {
        switch self {
        case .app, .tools, .trash: true
        case .widget, .divider: false
        }
    }

    /// How much of the Dock's length it takes before anything grows.
    func length(icon: CGFloat, vertical: Bool) -> CGFloat {
        switch self {
        case .widget: vertical ? icon : icon * 1.9
        case .divider: 13
        default: icon
        }
    }
}

/// UniMacHub's Dock: widgets at the ends, the apps, UniMacHub's own tools and the Trash.
struct DockView: View {
    let model: DockModel
    let state: AppState

    static let spacing: CGFloat = 6

    var body: some View {
        let vertical = model.position.isVertical
        let icon = CGFloat(model.iconSize)
        let entries = entries()
        let lengths = entries.map { $0.length(icon: icon, vertical: vertical) }
        let padding = DockController.padding
        let base = lengths.reduce(0, +) + Self.spacing * CGFloat(max(0, entries.count - 1)) + 2 * padding
        let centres = lengths.indices.map { index in
            padding + lengths[..<index].reduce(0, +) + Self.spacing * CGFloat(index) + lengths[index] / 2
        }
        // The pointer, measured from the start of the Dock as it would be laid out unmagnified.
        let pointer = model.pointer.map { $0 + base / 2 }
        let scales = entries.indices.map { index -> CGFloat in
            guard let pointer, entries[index].grows, model.magnifies else { return 1 }
            return DockMagnification.scale(distance: pointer - centres[index], iconSize: icon, magnification: CGFloat(model.magnification))
        }
        let nearest = pointer.flatMap { pointer in
            entries.indices.filter { entries[$0].grows }.min { abs(centres[$0] - pointer) < abs(centres[$1] - pointer) }
        }
        let layout = vertical
            ? AnyLayout(VStackLayout(alignment: model.position == .left ? .leading : .trailing, spacing: Self.spacing))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: Self.spacing))

        layout {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                tile(entry, size: icon * scales[index], icon: icon, label: index == nearest)
            }
        }
        .padding(padding)
        .padding(vertical ? .horizontal : .vertical, 0)
        .background(alignment: edgeAlignment) {
            DockBackground()
                .frame(
                    width: vertical ? icon + 2 * padding + DockController.indicator : nil,
                    height: vertical ? nil : icon + 2 * padding + DockController.indicator
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            let apps = urls.filter { $0.pathExtension == "app" }
            apps.forEach(model.pin)
            return !apps.isEmpty
        }
        .offset(hiddenOffset(icon: icon))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edgeAlignment)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.isShown)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.86), value: model.pointer)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: entries.map(\.id))
        .onAppear { model.barLength = base }
        .onChange(of: base) { _, length in model.barLength = length }
    }

    private var edgeAlignment: Alignment {
        switch model.position {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    /// Slid out of sight past the edge while hidden.
    private func hiddenOffset(icon: CGFloat) -> CGSize {
        guard !model.isShown else { return .zero }
        let distance = icon + 2 * DockController.padding + DockController.indicator + 12
        switch model.position {
        case .bottom: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        }
    }

    private func entries() -> [DockEntry] {
        var result: [DockEntry] = []
        let leading = DockModel.Widget.allCases.filter { model.widgets.contains($0) && $0.leading }
        let trailing = DockModel.Widget.allCases.filter { model.widgets.contains($0) && !$0.leading }
        result += leading.map(DockEntry.widget)
        if !leading.isEmpty { result.append(.divider(0)) }
        let pinned = model.apps.filter(\.isPinned)
        let others = model.apps.filter { !$0.isPinned }
        result += pinned.map(DockEntry.app)
        if !others.isEmpty {
            if !pinned.isEmpty { result.append(.divider(1)) }
            result += others.map(DockEntry.app)
        }
        if model.showsTools {
            result.append(.divider(2))
            result += SidebarSection.allCases.map(DockEntry.tools)
        }
        result.append(.divider(3))
        result.append(.trash)
        if !trailing.isEmpty {
            result.append(.divider(4))
            result += trailing.map(DockEntry.widget)
        }
        return result
    }

    @ViewBuilder private func tile(_ entry: DockEntry, size: CGFloat, icon: CGFloat, label: Bool) -> some View {
        let vertical = model.position.isVertical
        switch entry {
        case let .app(app):
            AppTile(app: app, model: model, size: size, label: label)
        case let .tools(section):
            ToolTile(section: section, state: state, size: size, label: label, position: model.position)
        case .trash:
            TrashTile(model: model, size: size, label: label, position: model.position)
        case .divider:
            Rectangle().fill(.white.opacity(0.25))
                .frame(width: vertical ? icon * 0.7 : 1, height: vertical ? 1 : icon * 0.7)
                .padding(vertical ? .vertical : .horizontal, 6)
                .frame(height: vertical ? nil : icon + DockController.indicator, alignment: .center)
        case let .widget(widget):
            DockWidgetView(widget: widget, model: model, state: state, compact: vertical)
                .frame(width: vertical ? icon : icon * 1.9, height: icon)
                .padding(vertical ? .vertical : .bottom, vertical ? 0 : DockController.indicator)
        }
    }
}

/// The Dock's own glass.
private struct DockBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The name above an icon, as the system Dock shows it.
private struct DockLabel: ViewModifier {
    let text: Text
    let shown: Bool
    let position: DockModel.Position

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if shown {
                text
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: .capsule)
                    .offset(offset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private var alignment: Alignment {
        switch position {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }

    private var offset: CGSize {
        switch position {
        case .bottom: CGSize(width: 0, height: -34)
        case .left: CGSize(width: 140, height: 0)
        case .right: CGSize(width: -140, height: 0)
        }
    }
}

private struct AppTile: View {
    let app: DockModel.App
    let model: DockModel
    let size: CGFloat
    let label: Bool
    @State private var bounce = false

    var body: some View {
        VStackOrHStack(vertical: model.position.isVertical, reversed: model.position == .left) {
            Image(nsImage: model.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .offset(y: bounce ? -size * 0.3 : 0)
            Circle()
                .fill(.white.opacity(app.isRunning && model.showsIndicators ? 0.85 : 0))
                .frame(width: 4, height: 4)
                .frame(width: model.position.isVertical ? DockController.indicator : nil,
                       height: model.position.isVertical ? nil : DockController.indicator)
        }
        .modifier(DockLabel(text: Text(verbatim: app.name), shown: label, position: model.position))
        .contentShape(.rect)
        .onTapGesture { model.open(app) }
        .contextMenu {
            if app.isRunning {
                Button("Show") { model.open(app) }
                Button("Quit") { model.quit(app) }
            } else {
                Button("Open") { model.open(app) }
            }
            Divider()
            Button("Show in Finder") { model.showInFinder(app) }
            if app.isPinned {
                Button("Remove from Dock") { model.unpin(app) }
            } else {
                Button("Keep in Dock") { model.pin(app.url) }
            }
        }
        .draggable(app.url)
        .dropDestination(for: URL.self) { urls, _ in
            // Another pinned app dropped here moves in front of this one; files open in it.
            if urls.count == 1, let url = urls.first, url.pathExtension == "app", app.isPinned, url != app.url {
                if model.pinned.contains(url) { model.move(url, before: app.url) } else { model.pin(url) }
                return true
            }
            model.open(urls, with: app)
            return true
        }
        .onChange(of: app.isLaunching, initial: true) { _, launching in
            if launching {
                withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) { bounce = true }
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { bounce = false }
            }
        }
    }
}

/// A stack that runs along the Dock's thickness: the icon, then its dot towards the edge.
private struct VStackOrHStack<Content: View>: View {
    let vertical: Bool
    let reversed: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if vertical {
            HStack(spacing: 0) { content }
                .environment(\.layoutDirection, reversed ? .rightToLeft : .leftToRight)
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

/// A section of UniMacHub, opening to its tools.
private struct ToolTile: View {
    let section: SidebarSection
    let state: AppState
    let size: CGFloat
    let label: Bool
    let position: DockModel.Position

    var body: some View {
        Menu {
            ForEach(section.modules.filter { !$0.isPlanned }) { module in
                Button {
                    state.showMain(module)
                } label: {
                    Label { Text(module.title) } icon: { Image(systemName: module.symbol) }
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.accentLight, Palette.accent], startPoint: .top, endPoint: .bottom))
                Image(systemName: section.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size * 0.86, height: size * 0.86)
            .frame(width: size, height: size)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(position.isVertical ? .horizontal : .bottom, DockController.indicator / 2)
        .modifier(DockLabel(text: Text(section.title), shown: label, position: position))
    }
}

private struct TrashTile: View {
    let model: DockModel
    let size: CGFloat
    let label: Bool
    let position: DockModel.Position
    @State private var targeted = false

    var body: some View {
        Group {
            if let image = NSImage(named: model.trashIsFull ? "NSTrashFull" : "NSTrashEmpty") {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: model.trashIsFull ? "trash.fill" : "trash").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(targeted ? 1.1 : 1)
        .padding(position.isVertical ? .horizontal : .bottom, DockController.indicator / 2)
        .modifier(DockLabel(text: Text("Trash"), shown: label, position: position))
        .contentShape(.rect)
        .onTapGesture { model.openTrash() }
        .dropDestination(for: URL.self) { urls, _ in
            model.moveToTrash(urls)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
    }
}

// MARK: - Widgets

private struct DockWidgetView: View {
    let widget: DockModel.Widget
    let model: DockModel
    let state: AppState
    let compact: Bool

    var body: some View {
        content
            .padding(compact ? 6 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch widget {
        case .clock: ClockWidget(compact: compact)
        case .system: SystemWidget(monitor: state.monitor, compact: compact)
        case .controls: ControlsWidget(compact: compact)
        case .music: MusicWidget(island: state.island, compact: compact)
        case .calendar: CalendarWidget(calendar: state.island.calendar, compact: compact)
        case .weather: WeatherWidget(model: model, compact: compact)
        }
    }
}

private struct ClockWidget: View {
    let compact: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: compact ? 17 : 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                if !compact {
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct SystemWidget: View {
    let monitor: MenuBarMonitor
    let compact: Bool

    var body: some View {
        let sample = monitor.sample
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            row("cpu", "\(Int((sample.cpu * 100).rounded()))%")
            if let memory = sample.memory { row("memorychip", "\(Int((memory.usedFraction * 100).rounded()))%") }
            if !compact {
                row("arrow.down.arrow.up", "\(speed(sample.download)) · \(speed(sample.upload))")
                if let temperature = sample.temperature {
                    row("thermometer.medium", "\(Int(temperature.rounded()))°")
                } else if let disk = sample.disk {
                    row("internaldrive", disk.availableCapacity.formatted(.byteCount(style: .file)))
                }
            }
        }
        .font(.system(size: compact ? 10 : 11, weight: .medium).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { monitor.start() }
    }

    private func row(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(.white.opacity(0.6))
            Text(verbatim: value).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func speed(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file)) + "/s"
    }
}

/// Wi-Fi, Bluetooth and sound, the switches the author keeps in the Dock.
private struct ControlsWidget: View {
    let compact: Bool
    @State private var wifi = CWWiFiClient.shared().interface()?.powerOn() ?? false
    @State private var muted = SystemVolume.isMuted()

    var body: some View {
        let buttons = Group {
            round(wifi ? "wifi" : "wifi.slash", on: wifi) {
                guard let interface = CWWiFiClient.shared().interface() else { return }
                try? interface.setPower(!wifi)
                wifi = interface.powerOn()
            }
            round("dot.radiowaves.left.and.right", on: true) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
            }
            round(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: !muted) {
                _ = SystemVolume.setMuted(!muted)
                muted = SystemVolume.isMuted()
            }
        }
        if compact {
            VStack(spacing: 4) { buttons }
        } else {
            HStack(spacing: 8) { buttons }
        }
    }

    private func round(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 14, weight: .semibold))
                .frame(width: compact ? 22 : 38, height: compact ? 22 : 38)
                .background(on ? Palette.accent : Color.white.opacity(0.15), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

private struct MusicWidget: View {
    let island: IslandModel
    let compact: Bool

    var body: some View {
        if let session = island.featured {
            HStack(spacing: 8) {
                artwork(session)
                if !compact {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: session.title).font(.caption.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 12) {
                            Button { island.playPause(session) } label: {
                                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            }
                            Button { island.nextTrack(session) } label: { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onTapGesture { if compact { island.playPause(session) } }
        } else {
            Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func artwork(_ session: NowPlaying) -> some View {
        Group {
            if let image = island.artwork(for: session) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.1))
            }
        }
        .frame(width: compact ? 40 : 52, height: compact ? 40 : 52)
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct CalendarWidget: View {
    let calendar: CalendarFeed
    let compact: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: compact ? .center : .leading, spacing: 2) {
                Text(context.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
                Text(context.date.formatted(.dateTime.day()))
                    .font(.system(size: compact ? 18 : 22, weight: .semibold, design: .rounded))
                if !compact, let event = calendar.next {
                    Text(verbatim: "\(event.start.formatted(date: .omitted, time: .shortened)) \(event.title)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        }
        .onAppear { if !calendar.isEnabled { calendar.isEnabled = true } }
    }
}

private struct WeatherWidget: View {
    let model: DockModel
    let compact: Bool

    var body: some View {
        if let weather = model.weather {
            HStack(spacing: 8) {
                Image(systemName: Weather.symbol(for: weather.code, isDay: weather.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: compact ? 18 : 26))
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(Int(weather.temperature.rounded()))°")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text(verbatim: model.weatherTown).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                }
            }
        } else {
            Image(systemName: model.weatherError ? "exclamationmark.icloud" : "cloud.sun")
                .font(.title2).foregroundStyle(.white.opacity(0.45))
                .help(Text("Name a town in Dock & Widgets"))
        }
    }
}
