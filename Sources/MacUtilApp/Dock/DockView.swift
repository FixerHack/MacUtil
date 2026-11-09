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

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let vertical = model.position.isVertical
            let alongLength = vertical ? size.height : size.width
            let entries = model.entries
            let layout = model.layout(entries, available: alongLength - 24, pointer: model.pointer)
            let geometry = DockGeometry(position: model.position, layout: layout, alongLength: alongLength)

            ZStack(alignment: .topLeading) {
                bar(geometry, size: size)
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    place(entry, layout.items[index], geometry, size: size)
                }
                if let hovered = layout.hovered, entries.indices.contains(hovered) {
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
        guard !model.isShown else { return .zero }
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
            .dropDestination(for: URL.self) { urls, _ in
                let apps = urls.filter { $0.pathExtension == "app" }
                apps.forEach(model.pin)
                return !apps.isEmpty
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
            DockWidgetView(widget: widget, model: model, sources: sources, icon: geometry.icon, compact: geometry.vertical)
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
