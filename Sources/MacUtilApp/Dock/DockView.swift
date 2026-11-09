import AppKit
import CleanerCore
import SwiftUI

/// UniMacHub's Dock, drawn the way the system one is: one glass bar with the apps, a line
/// between groups, a dot under what is running, the Trash at the end, and widgets at the ends.
///
/// Everything is placed by hand from `DockLayout`, the same numbers the controller uses to
/// decide what is under the pointer, so the icon that grows is always the one beneath it.
struct DockView: View {
    let model: DockModel
    let sources: DockSources
    let state: DockPanelState

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let vertical = model.position.isVertical
            let alongLength = vertical ? size.height : size.width
            let entries = model.entries
            let layout = model.layout(entries, available: alongLength - 24, pointer: state.pointer)
            let geometry = DockGeometry(position: model.position, layout: layout, alongLength: alongLength)

            ZStack(alignment: .topLeading) {
                bar(geometry, size: size)
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    place(entry, layout.items[index], geometry, size: size)
                }
                if state.openFolder == nil, let hovered = layout.hovered, entries.indices.contains(hovered) {
                    label(for: entries[hovered], at: layout.items[hovered], geometry, size: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(hiddenOffset(geometry))
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.entries.map(\.id))
    }

    /// Slid out past the edge while hidden.
    private func hiddenOffset(_ geometry: DockGeometry) -> CGSize {
        guard !state.isShown else { return .zero }
        let distance = DockGeometry.margin + geometry.thickness + 12
        switch model.position {
        case .bottom: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        }
    }

    // MARK: - The bar

    private func bar(_ geometry: DockGeometry, size: CGSize) -> some View {
        let layout = geometry.layout
        let length = layout.barEnd - layout.barStart
        let thickness = geometry.thickness
        let centre = geometry.point(
            along: geometry.offset + (layout.barStart + layout.barEnd) / 2,
            depth: DockGeometry.margin + thickness / 2,
            in: size
        )
        let radius = min(thickness / 2, geometry.icon * 0.36)
        return DockGlass(cornerRadius: radius)
            .frame(width: geometry.vertical ? thickness : length, height: geometry.vertical ? length : thickness)
            .contextMenu {
                if !model.profiles.isEmpty {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.switchProfile(to: profile.id)
                        } label: {
                            if model.activeProfile == profile.id {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: profile.name)
                            }
                        }
                    }
                    Divider()
                }
                Button("Dock Settings…") { sources.openInHub(.dockWidgets) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Apps join the apps; folders go by the Trash, as in the system Dock.
                let apps = urls.filter { $0.pathExtension == "app" }
                let folders = urls.filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                apps.forEach(model.pin)
                folders.forEach(model.pinFolder)
                return !apps.isEmpty || !folders.isEmpty
            }
            .position(centre)
    }

    // MARK: - What is on it

    @ViewBuilder
    private func place(_ entry: DockModel.Entry, _ item: DockLayout.Placed, _ geometry: DockGeometry, size: CGSize) -> some View {
        let along = geometry.offset + item.centre
        switch entry {
        case let .app(app):
            let side = geometry.icon * item.scale
            AppTile(app: app, model: model, sources: sources, side: side, position: model.position)
                .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.edgeInset + side / 2, in: size))
            if app.isRunning, model.showsIndicators {
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.edgeInset / 2, in: size))
                    .allowsHitTesting(false)
            }
        case let .window(window):
            let side = geometry.icon * item.scale
            WindowTile(window: window, model: model, tracker: sources.windows, side: side)
                .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.edgeInset + side / 2, in: size))
        case let .folder(url):
            let side = geometry.icon * item.scale
            FolderTile(folder: url, model: model, state: state, side: side, position: model.position)
                .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.edgeInset + side / 2, in: size))
        case .trash:
            let side = geometry.icon * item.scale
            TrashTile(model: model, side: side)
                .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.edgeInset + side / 2, in: size))
        case .divider:
            let line = geometry.icon * 0.62
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(width: geometry.vertical ? line : 1, height: geometry.vertical ? 1 : line)
                .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.thickness / 2, in: size))
                .allowsHitTesting(false)
        case let .widget(widget):
            let gap = geometry.icon * 0.1
            let length = item.length - gap
            let across = geometry.icon - gap
            DockWidgetView(widget: widget, model: model, sources: sources, state: state, icon: geometry.icon, compact: geometry.vertical)
                .frame(width: geometry.vertical ? across : length, height: geometry.vertical ? length : across)
                .position(geometry.point(along: along, depth: DockGeometry.margin + geometry.edgeInset + geometry.icon / 2, in: size))
        }
    }

    // MARK: - The name over an icon

    @ViewBuilder
    private func label(for entry: DockModel.Entry, at item: DockLayout.Placed, _ geometry: DockGeometry, size: CGSize) -> some View {
        let text: Text? = switch entry {
        case let .app(app): Text(verbatim: app.name)
        case .trash: Text("Trash")
        case let .folder(url): Text(verbatim: FileManager.default.displayName(atPath: url.path))
        case let .window(window): Text(verbatim: window.title.isEmpty ? window.appName : window.title)
        default: nil
        }
        if let text {
            let side = geometry.icon * item.scale
            let depth = DockGeometry.margin + geometry.edgeInset + side + 10
            let room = DockGeometry.labelRoom(vertical: geometry.vertical) - 20
            let alignment: Alignment = switch model.position {
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            }
            text
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(.black.opacity(0.72), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .frame(width: geometry.vertical ? room : 600, height: geometry.vertical ? 30 : room, alignment: alignment)
                .position(geometry.point(along: geometry.offset + item.centre, depth: depth + room / 2, in: size))
                .allowsHitTesting(false)
        }
    }
}

/// The Dock's own glass: Liquid Glass where macOS has it, a blurred panel before that.
private struct DockGlass: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            VisualEffect()
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                )
        }
    }

    private struct VisualEffect: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

// MARK: - Tiles

private struct AppTile: View {
    let app: DockModel.App
    let model: DockModel
    let sources: DockSources
    let side: CGFloat
    let position: DockModel.Position
    @State private var bounce = false

    var body: some View {
        Image(nsImage: model.icon(for: app.url))
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .offset(bounceOffset)
            .contentShape(.rect)
            .onTapGesture { model.open(app) }
            .contextMenu {
                // UniMacHub's own icon opens straight onto any of its tools.
                if app.bundleID == MacUtilInfo.bundleIdentifier {
                    ForEach(SidebarSection.allCases) { section in
                        Menu {
                            ForEach(section.modules.filter { !$0.isPlanned }) { module in
                                Button {
                                    sources.openInHub(module)
                                } label: {
                                    Label { Text(module.title) } icon: { Image(systemName: module.symbol) }
                                }
                            }
                        } label: {
                            Label { Text(section.title) } icon: { Image(systemName: section.symbol) }
                        }
                    }
                    Divider()
                }
                if app.isRunning {
                    Button("Show") { model.open(app) }
                    Button("Hide") { model.hide(app) }
                    Button("Quit") { model.quit(app) }
                } else {
                    Button("Open") { model.open(app) }
                }
                Divider()
                Button("Show in Finder") { model.showInFinder(app) }
                if app.isPinned {
                    Button("Remove from Dock") { model.unpin(app.url) }
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

    /// Away from the edge, the way a launching app jumps in the system Dock.
    private var bounceOffset: CGSize {
        guard bounce else { return .zero }
        let distance = side * 0.32
        switch position {
        case .bottom: return CGSize(width: 0, height: -distance)
        case .left: return CGSize(width: distance, height: 0)
        case .right: return CGSize(width: -distance, height: 0)
        }
    }
}

/// A minimised window: a small window with its app's icon on it. A click brings it back.
private struct WindowTile: View {
    let window: MinimizedWindow
    let model: DockModel
    let tracker: MinimizedWindows
    let side: CGFloat

    var body: some View {
        let card = side * 0.8
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: card * 0.12, style: .continuous)
                .fill(.white.opacity(0.14))
            RoundedRectangle(cornerRadius: card * 0.12, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            // The bar along a window's top, with its three buttons.
            HStack(spacing: card * 0.04) {
                ForEach([Color.red, .yellow, .green], id: \.self) { colour in
                    Circle().fill(colour.opacity(0.8)).frame(width: card * 0.07, height: card * 0.07)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, card * 0.08)
            .padding(.top, card * 0.07)
        }
        .frame(width: card, height: card * 0.78)
        .overlay(alignment: .bottomTrailing) {
            if let url = window.appURL {
                Image(nsImage: model.icon(for: url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: card * 0.62, height: card * 0.62)
                    .offset(x: card * 0.12, y: card * 0.14)
            }
        }
        .frame(width: side, height: side)
        .contentShape(.rect)
        .onTapGesture { tracker.restore(window) }
        .contextMenu {
            Button("Show") { tracker.restore(window) }
            Button("Close Window") { tracker.close(window) }
        }
    }
}

/// A folder kept in the Dock. A click opens what is in it over the Dock.
private struct FolderTile: View {
    let folder: URL
    let model: DockModel
    let state: DockPanelState
    let side: CGFloat
    let position: DockModel.Position

    var body: some View {
        let isOpen = Binding(
            get: { state.openFolder == folder },
            set: { open in
                if open { state.openFolder = folder } else if state.openFolder == folder { state.openFolder = nil }
            }
        )
        Image(nsImage: model.icon(for: folder))
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .contentShape(.rect)
            .onTapGesture { isOpen.wrappedValue.toggle() }
            .popover(isPresented: isOpen, arrowEdge: arrowEdge) {
                FolderStack(folder: folder, model: model) { isOpen.wrappedValue = false }
            }
            .contextMenu {
                Button("Open in Finder") { NSWorkspace.shared.open(folder) }
                Picker("Show as", selection: Binding(get: { model.folderStyle }, set: { model.folderStyle = $0 })) {
                    Text("Fan out").tag(DockModel.FolderStyle.fan)
                    Text("Grid").tag(DockModel.FolderStyle.grid)
                    Text("List").tag(DockModel.FolderStyle.list)
                }
                Divider()
                Button("Remove from Dock") { model.unpinFolder(folder) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Dropped on the folder: moved into it, as Finder would.
                for url in urls where url.isFileURL && url.deletingLastPathComponent() != folder {
                    try? FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
                }
                return true
            }
    }

    /// The popover points back at the Dock, from the side away from the edge.
    private var arrowEdge: Edge {
        switch position {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

/// What is in a folder: a fan rising from the Dock, a grid, or a list, newest first.
private struct FolderStack: View {
    let folder: URL
    let model: DockModel
    let close: () -> Void

    var body: some View {
        let style = model.folderStyle
        let items = DockModel.contents(of: folder, limit: style == .fan ? 12 : 60)
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("This folder is empty")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                switch style {
                case .fan: fan(items)
                case .grid: grid(items)
                case .list: list(items)
                }
            }
            Divider()
            Button {
                NSWorkspace.shared.open(folder)
                close()
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        close()
    }

    private func name(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    private func grid(_ items: [URL]) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 6), count: 4), spacing: 10) {
                ForEach(items, id: \.self) { url in
                    VStack(spacing: 4) {
                        Image(nsImage: model.icon(for: url)).resizable().interpolation(.high).frame(width: 52, height: 52)
                        Text(verbatim: name(url))
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(height: 30, alignment: .top)
                    }
                    .frame(width: 84)
                    .contentShape(.rect)
                    .onTapGesture { open(url) }
                    .draggable(url)
                }
            }
        }
        .frame(width: 4 * 84 + 3 * 6 + 8, height: min(380, CGFloat((items.count + 3) / 4) * 100 + 8))
    }

    private func list(_ items: [URL]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(nsImage: model.icon(for: url)).resizable().interpolation(.high).frame(width: 20, height: 20)
                        Text(verbatim: name(url)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                    .onTapGesture { open(url) }
                    .draggable(url)
                }
            }
        }
        .frame(width: 280, height: min(420, CGFloat(items.count) * 27 + 4))
    }

    /// Names on the left, icons on the right, curving slightly as they rise.
    private func fan(_ items: [URL]) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(items.reversed().enumerated()), id: \.element) { index, url in
                let step = CGFloat(items.count - 1 - index)
                HStack(spacing: 8) {
                    Text(verbatim: name(url))
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.35), in: .capsule)
                    Image(nsImage: model.icon(for: url)).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
                .offset(x: -step * step * 1.6)
                .contentShape(.rect)
                .onTapGesture { open(url) }
                .draggable(url)
            }
        }
        .frame(width: 300, alignment: .trailing)
    }
}

private struct TrashTile: View {
    let model: DockModel
    let side: CGFloat
    @State private var targeted = false

    var body: some View {
        Group {
            if let image = NSImage(named: model.trashIsFull ? "NSTrashFull" : "NSTrashEmpty") {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: model.trashIsFull ? "trash.fill" : "trash").resizable().scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(targeted ? 1.1 : 1)
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

/// A widget's card. Everything in it is sized from the icon size, so it shrinks with the Dock.
private struct DockWidgetView: View {
    let widget: DockModel.Widget
    let model: DockModel
    let sources: DockSources
    let state: DockPanelState
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        content
            .padding(icon * 0.1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.09), in: .rect(cornerRadius: icon * 0.2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: icon * 0.2, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
            .clipShape(.rect(cornerRadius: icon * 0.2, style: .continuous))
            .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch widget {
        case .clock: ClockWidget(icon: icon, compact: compact)
        case .system: SystemWidget(sample: sources.sample, icon: icon, compact: compact)
        case .music: MusicWidget(island: sources.island, model: model, icon: icon, compact: compact)
        case .calendar: CalendarWidget(calendar: sources.island.calendar, icon: icon, compact: compact)
        case .weather: WeatherWidget(model: model, icon: icon, compact: compact)
        case .timer: TimerWidget(gadgets: sources.gadgets, icon: icon, compact: compact)
        case .pomodoro: PomodoroWidget(gadgets: sources.gadgets, icon: icon, compact: compact)
        case .clipboard: ClipboardWidget(state: state, icon: icon)
        case .colourPicker: ColourWidget(gadgets: sources.gadgets, icon: icon)
        case .calculator: CalculatorWidget(state: state, icon: icon)
        }
    }
}

private struct ClockWidget: View {
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: icon * 0.02) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: icon * (compact ? 0.24 : 0.3), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !compact {
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(size: icon * 0.14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SystemWidget: View {
    let sample: SystemStats.Sample
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: icon * 0.02) {
            row("cpu", "\(Int((sample.cpu * 100).rounded()))%")
            if let memory = sample.memory { row("memorychip", "\(Int((memory.usedFraction * 100).rounded()))%") }
            if !compact {
                row("arrow.down", speed(sample.download))
                if let temperature = sample.temperature {
                    row("thermometer.medium", "\(Int(temperature.rounded()))°")
                } else {
                    row("arrow.up", speed(sample.upload))
                }
            }
        }
        .font(.system(size: icon * (compact ? 0.15 : 0.135), weight: .medium).monospacedDigit())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: icon * 0.05) {
            Image(systemName: symbol).frame(width: icon * 0.16).foregroundStyle(.white.opacity(0.6))
            Text(verbatim: value).lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private func speed(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file)) + "/s"
    }
}

/// What plays, with its controls. It stands in for the music apps: a click on the cover
/// opens the one playing, or Music when nothing is.
private struct MusicWidget: View {
    let island: IslandModel
    let model: DockModel
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        if let session = island.featured {
            HStack(spacing: icon * 0.1) {
                artwork(session)
                    .onTapGesture {
                        if compact { island.playPause(session) } else { model.open(bundleID: session.bundleID) }
                    }
                if !compact {
                    VStack(alignment: .leading, spacing: icon * 0.04) {
                        Text(verbatim: session.title)
                            .font(.system(size: icon * 0.15, weight: .semibold))
                            .lineLimit(1)
                        if !session.artist.isEmpty {
                            Text(verbatim: session.artist)
                                .font(.system(size: icon * 0.13))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        HStack(spacing: icon * 0.16) {
                            Button { island.previousTrack(session) } label: { Image(systemName: "backward.fill") }
                            Button { island.playPause(session) } label: {
                                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            }
                            Button { island.nextTrack(session) } label: { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: icon * 0.17))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            HStack(spacing: icon * 0.1) {
                Image(systemName: "music.note")
                    .font(.system(size: icon * 0.3))
                    .frame(width: icon * 0.6, height: icon * 0.6)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: icon * 0.12, style: .continuous))
                if !compact {
                    Text("Nothing is playing")
                        .font(.system(size: icon * 0.14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
            .contentShape(.rect)
            .onTapGesture { model.open(bundleID: NowPlaying.Player.music.bundleID) }
        }
    }

    private func artwork(_ session: NowPlaying) -> some View {
        let side = icon * (compact ? 0.7 : 0.62)
        return Group {
            if let image = island.artwork(for: session) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: icon * 0.1, style: .continuous))
        .contentShape(.rect)
    }
}

private struct CalendarWidget: View {
    let calendar: CalendarFeed
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: compact ? .center : .leading, spacing: 0) {
                Text(context.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: icon * 0.12, weight: .bold))
                    .foregroundStyle(.red)
                Text(context.date.formatted(.dateTime.day()))
                    .font(.system(size: icon * (compact ? 0.3 : 0.27), weight: .semibold, design: .rounded))
                if !compact, let event = calendar.next {
                    Text(verbatim: "\(event.start.formatted(date: .omitted, time: .shortened)) \(event.title)")
                        .font(.system(size: icon * 0.11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
        }
        .contentShape(.rect)
        .onTapGesture {
            NSWorkspace.shared.open(URL(filePath: "/System/Applications/Calendar.app"))
        }
    }
}

private struct WeatherWidget: View {
    let model: DockModel
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        if let weather = model.weather {
            HStack(spacing: icon * 0.08) {
                Image(systemName: Weather.symbol(for: weather.code, isDay: weather.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: icon * (compact ? 0.3 : 0.34)))
                if !compact {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "\(Int(weather.temperature.rounded()))°")
                            .font(.system(size: icon * 0.26, weight: .semibold, design: .rounded))
                        Text(verbatim: model.weatherTown)
                            .font(.system(size: icon * 0.12))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: "cloud.sun")
                .font(.system(size: icon * 0.3))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help(Text("Name a town in Dock & Widgets"))
        }
    }
}

// MARK: - Small tools

/// How long is left, as the system writes durations: 4:05, or 1:02:00.
private func remaining(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}

/// A ring that empties as time runs out.
private struct CountdownRing: View {
    let fraction: Double
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

private struct TimerWidget: View {
    let gadgets: DockGadgets
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: icon * 0.08) {
                if let end = gadgets.timerEnd {
                    let left = end.timeIntervalSince(context.date)
                    CountdownRing(fraction: left / max(gadgets.timerLength, 1), tint: .orange, size: icon * 0.36)
                    if !compact {
                        Text(verbatim: remaining(left))
                            .font(.system(size: icon * 0.2, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                } else {
                    Image(systemName: gadgets.timerRang ? "bell.and.waves.left.and.right.fill" : "timer")
                        .font(.system(size: icon * 0.3))
                        .foregroundStyle(gadgets.timerRang ? Color.orange : .white)
                        .symbolEffect(.bounce, value: gadgets.timerRang)
                    if !compact {
                        Text(gadgets.timerRang ? "Time's up" : "Timer")
                            .font(.system(size: icon * 0.14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(.rect)
        .onTapGesture { menu() }
    }

    private func menu() {
        let menu = NSMenu()
        if gadgets.timerEnd != nil {
            menu.addItem(ClosureMenuItem(title: String(localized: "Stop Timer")) { gadgets.stopTimer() })
            menu.addItem(.separator())
        }
        for minutes in [1, 3, 5, 10, 15, 20, 30, 45, 60] {
            menu.addItem(ClosureMenuItem(title: String(localized: "\(minutes) min")) { gadgets.startTimer(minutes: minutes) })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private struct PomodoroWidget: View {
    let gadgets: DockGadgets
    let icon: CGFloat
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = gadgets.phaseEnd.map { $0.timeIntervalSince(context.date) } ?? gadgets.pausedLeft ?? gadgets.phaseLength
            let tint: Color = gadgets.phase == .focus ? .red : .green
            HStack(spacing: icon * 0.08) {
                ZStack {
                    CountdownRing(fraction: left / gadgets.phaseLength, tint: tint, size: icon * 0.4)
                    Image(systemName: gadgets.pomodoroRunning ? (gadgets.phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill") : "play.fill")
                        .font(.system(size: icon * 0.14))
                }
                if !compact {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(gadgets.phase == .focus ? "Focus" : "Break")
                            .font(.system(size: icon * 0.12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(verbatim: remaining(left))
                            .font(.system(size: icon * 0.19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(.rect)
        .onTapGesture { gadgets.togglePomodoro() }
        .contextMenu {
            Button("Skip to the Next Part") { gadgets.skipPhase() }
            Button("Reset") { gadgets.resetPomodoro() }
        }
    }
}

/// What was copied lately, from UniMacHub's clipboard history.
private struct ClipboardWidget: View {
    let state: DockPanelState
    let icon: CGFloat

    var body: some View {
        Image(systemName: "list.clipboard")
            .font(.system(size: icon * 0.32))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture { toggle() }
            .popover(isPresented: Binding(
                get: { state.openWidget == .clipboard },
                set: { if !$0, state.openWidget == .clipboard { state.openWidget = nil } }
            )) {
                ClipboardList { state.openWidget = nil }
            }
    }

    private func toggle() {
        state.openWidget = state.openWidget == .clipboard ? nil : .clipboard
    }
}

private struct ClipboardList: View {
    let close: () -> Void
    @State private var entries: [ClipboardEntry] = []

    /// The history is switched on in UniMacHub, whose setting this is.
    private var isOn: Bool {
        UserDefaults(suiteName: MacUtilInfo.bundleIdentifier)?.bool(forKey: ClipboardHistory.enabledKey) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isOn {
                Text("Clipboard history is off. Turn it on in UniMacHub under Overview → Clipboard History.")
                    .foregroundStyle(.secondary)
                    .frame(width: 260)
                    .padding(8)
            } else if entries.isEmpty {
                Text("Nothing copied yet")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries.prefix(20)) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.kind == .url ? "link" : entry.kind == .file ? "doc" : "text.alignleft")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(verbatim: entry.preview).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(.rect)
                            .onTapGesture {
                                ClipboardHistory.copy(entry)
                                close()
                            }
                        }
                    }
                }
                .frame(width: 320, height: min(400, CGFloat(min(entries.count, 20)) * 26 + 6))
                Text("Click one to copy it again")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .padding(8)
        .onAppear { entries = ClipboardHistory.load() }
    }
}

private struct ColourWidget: View {
    let gadgets: DockGadgets
    let icon: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "eyedropper.halffull")
                .font(.system(size: icon * 0.3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let last = gadgets.colours.first, let colour = NSColor(hex: last) {
                Circle()
                    .fill(Color(nsColor: colour))
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    .frame(width: icon * 0.2, height: icon * 0.2)
                    .help(Text(verbatim: last))
            }
        }
        .contentShape(.rect)
        .onTapGesture { gadgets.pickColour() }
        .contextMenu {
            ForEach(gadgets.colours, id: \.self) { hex in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hex, forType: .string)
                } label: {
                    Text(verbatim: hex)
                }
            }
        }
    }
}

private struct CalculatorWidget: View {
    let state: DockPanelState
    let icon: CGFloat

    var body: some View {
        Image(systemName: "plusminus.circle")
            .font(.system(size: icon * 0.32))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture { state.openWidget = state.openWidget == .calculator ? nil : .calculator }
            .popover(isPresented: Binding(
                get: { state.openWidget == .calculator },
                set: { if !$0, state.openWidget == .calculator { state.openWidget = nil } }
            )) {
                CalculatorPanel()
            }
    }
}

private struct CalculatorPanel: View {
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        let result = Arithmetic.evaluate(input).map(Arithmetic.format)
        VStack(alignment: .trailing, spacing: 6) {
            TextField("12 × (3 + 4) ÷ 2", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15).monospacedDigit())
                .focused($focused)
                .onSubmit { copy(result) }
            Text(verbatim: result.map { "= \($0)" } ?? (input.isEmpty ? " " : "…"))
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .textSelection(.enabled)
            Text("Return copies the answer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260)
        .onAppear {
            // A panel in an app that is never in front gets no typing until it is made key.
            NSApp.activate()
            focused = true
        }
    }

    private func copy(_ result: String?) {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }
}

