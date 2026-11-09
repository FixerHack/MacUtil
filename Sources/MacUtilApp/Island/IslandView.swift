import AppKit
import CleanerCore
import SwiftUI

/// The island itself: black like the notch it grows out of, wider when it has something to say.
///
/// It draws itself at the size of its state inside a window that is at least that big, and
/// springs from one size to the next, the shape and its content together. The content is
/// clipped to the shape, so while it grows the island reveals what is inside rather than
/// showing it before there is room.
struct IslandView: View {
    let model: IslandModel
    let state: AppState

    /// Opening: quick and with a little give, like the iPhone's.
    private static let opening = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// Everything else: unhurried and without overshoot, so nothing snaps shut.
    private static let settling = Animation.spring(response: 0.5, dampingFraction: 0.95)

    var body: some View {
        let presentation = model.presentation
        let size = model.geometry?.frame(for: presentation).size ?? .zero
        let shoulder = IslandGeometry.shoulder(for: presentation)
        let shape = IslandShape(shoulder: shoulder, bottom: IslandGeometry.bottomRadius(for: presentation))

        ZStack(alignment: .top) {
            Color.black
            content(presentation)
                .padding(.horizontal, shoulder)
        }
        .frame(width: size.width + 2 * shoulder, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(presentation == .expanded ? 0.5 : 0), radius: 14, y: 6)
        .contentShape(shape)
        .onTapGesture { model.tapped() }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.showsShelf else { return false }
            model.addToShelf(urls)
            return true
        } isTargeted: { model.isDropTargeted = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(presentation == .expanded ? Self.opening : Self.settling, value: presentation)
        .animation(.easeOut(duration: 0.15), value: model.indicator)
    }

    @ViewBuilder private func content(_ presentation: IslandGeometry.State) -> some View {
        switch presentation {
        case .collapsed:
            Color.clear
        case .wings:
            IslandWings(model: model)
                .transition(.islandContent)
        case .expanded:
            VStack(spacing: 0) {
                IslandTopStrip(model: model)
                    .frame(height: model.geometry?.resting.height ?? 24)
                    .padding(.horizontal, 22)
                ZStack {
                    if model.page == .agents, model.agents.showsAgents {
                        AgentsPage(model: model)
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
                    } else {
                        IslandPanel(model: model)
                            .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .clipped()
            }
            .transition(.islandContent)
        }
    }
}

extension AnyTransition {
    /// Content comes in out of a blur once the island has begun to open, and leaves quickly
    /// before it closes.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
                .animation(.spring(response: 0.4, dampingFraction: 0.9).delay(0.07)),
            removal: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

private struct BlurFade: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * amount)
            .opacity(1 - amount)
            .scaleEffect(1 - 0.06 * amount, anchor: .top)
    }
}

/// The notch's own shape: rounded at the bottom, and flared where it meets the top edge so it
/// pours out of the screen's edge instead of sitting on it with square corners.
struct IslandShape: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set {
            shoulder = newValue.first
            bottom = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottom, (rect.width - 2 * shoulder) / 2, rect.height - shoulder)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX + shoulder, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + shoulder, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Wings

/// One thing either side of the notch: the indicator, the work in hand, or the music. On a
/// screen without a notch the middle is free, so the title goes there.
private struct IslandWings: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            leading
                .font(.system(size: 13, weight: .semibold))
                .frame(width: IslandGeometry.wingWidth, alignment: .center)

            middle
                .frame(maxWidth: .infinity)

            trailing
                .frame(width: IslandGeometry.wingWidth, alignment: .center)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var leading: some View {
        if let indicator = model.indicator {
            Image(systemName: symbol(for: indicator))
                .contentTransition(.symbolEffect(.replace))
        } else if let agent = model.agents.attention {
            AgentSymbol(session: agent)
        } else if model.calendar.soon != nil {
            Image(systemName: "calendar").foregroundStyle(.red)
        } else if model.work != nil {
            ProgressView().controlSize(.small).tint(.white)
        } else if let session = model.featured {
            if let artwork = model.artwork(for: session) {
                Image(nsImage: artwork).resizable().scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(.rect(cornerRadius: 5))
            } else if let icon = model.appIcon(session.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "music.note")
            }
        }
    }

    @ViewBuilder private var middle: some View {
        if model.geometry?.hasNotch == false, model.indicator == nil {
            Group {
                if let agent = model.agents.attention {
                    Text(verbatim: "\(agent.project) · \(agent.stateText)")
                } else if let event = model.calendar.soon {
                    Text(verbatim: event.title)
                } else if let work = model.work {
                    Text(verbatim: work.title)
                } else if let session = model.featured {
                    Text(verbatim: session.title)
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder private var trailing: some View {
        if let indicator = model.indicator {
            LevelBar(level: indicator.muted ? 0 : indicator.level)
                .frame(width: 56, height: 5)
        } else if let agent = model.agents.attention {
            Text(verbatim: agent.wingText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(agent.needsYou ? Color.orange : .white.opacity(0.8))
                .lineLimit(1)
                .padding(.horizontal, 6)
        } else if let event = model.calendar.soon {
            Text(event.start, style: .relative)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
        } else if let work = model.work {
            if model.geometry?.hasNotch == true {
                Text(verbatim: work.title).lineLimit(1).font(.caption2)
            }
        } else if model.playing != nil {
            PlayingBars()
        } else if model.featured != nil {
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func symbol(for indicator: IslandModel.Indicator) -> String {
        switch indicator.kind {
        case .brightness: "sun.max.fill"
        case .player(.music): "music.note"
        case .player(.spotify): "music.note.list"
        case .volume:
            switch indicator.muted ? 0 : indicator.level {
            case 0: "speaker.slash.fill"
            case ..<0.34: "speaker.wave.1.fill"
            case ..<0.67: "speaker.wave.2.fill"
            default: "speaker.wave.3.fill"
            }
        }
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white)
                    .frame(width: max(0, geometry.size.width * CGFloat(level)))
            }
        }
    }
}

/// Bars that rise and fall while music plays. Only drawn while it plays, so they never keep
/// redrawing a quiet screen.
private struct PlayingBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Capsule()
                        .fill(Palette.accentLight)
                        .frame(width: 3, height: 4 + 9 * abs(sin(time * (2.6 + Double(index) * 0.45) + Double(index) * 1.3)))
                }
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Opened

/// The opened island: the music, the shelf, and this Mac.
private struct IslandPanel: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if model.showsNowPlaying {
                music.frame(width: model.showsShelf ? 290 : nil)
                    .frame(maxWidth: model.showsShelf ? nil : .infinity, alignment: .leading)
            }
            if model.showsShelf {
                shelf.frame(maxWidth: .infinity)
            }
            mac.frame(width: 140, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var music: some View {
        if model.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.4))
                Text("Nothing is playing")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                // A page per app; swipe sideways with two fingers, or press a dot below.
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(model.sessions) { session in
                            PlayerCard(session: session, model: model)
                                .containerRelativeFrame(.horizontal)
                                // A card that is not the one in view fades out, so the edge of
                                // the next never peeks in at the side; while swiping, the two
                                // cross over.
                                .scrollTransition(.interactive, axis: .horizontal) { card, phase in
                                    card
                                        .opacity(1 - min(1, abs(phase.value) * 1.6))
                                        .scaleEffect(1 - 0.06 * abs(phase.value))
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $model.selectedID)
                .scrollIndicators(.never)

                if model.sessions.count > 1 {
                    PlayerDots(model: model)
                }
            }
        }
    }

    private var shelf: some View {
        VStack(spacing: 6) {
            if model.shelf.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title2)
                        .symbolEffect(.bounce, value: model.isDropTargeted)
                    Text("Drop files here to keep them to hand")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(model.isDropTargeted ? 0.9 : 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.white.opacity(model.isDropTargeted ? 0.7 : 0.2))
                )
                .animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.shelf, id: \.self) { url in
                            VStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 36, height: 36)
                                Text(verbatim: url.lastPathComponent)
                                    .font(.caption2).lineLimit(1).truncationMode(.middle)
                                    .frame(width: 60)
                            }
                            .draggable(url)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Take Off the Shelf") { model.removeFromShelf(url) }
                            }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.shelf)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                HStack {
                    Button("AirDrop", systemImage: "airplayaudio") { model.airDropShelf() }
                    Spacer()
                    Button("Clear") { model.clearShelf() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var mac: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeepAwakeToggle()
            if let dock = model.dock, dock.isEnabled, !dock.profiles.isEmpty {
                DockProfileSwitch(dock: dock)
            }
            if model.calendar.isEnabled, let event = model.calendar.next {
                CalendarChip(event: event)
            }
            if let work = model.work {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(verbatim: work.title).font(.caption).lineLimit(2)
                }
            }
            Button {
                model.openMain?()
                model.close()
            } label: {
                Label("Open UniMacHub", systemImage: "circle.hexagongrid")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// One app's card: what it plays, how far in, and its buttons.
private struct PlayerCard: View {
    let session: NowPlaying
    let model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: session.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if !session.artist.isEmpty {
                        Text(verbatim: session.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Text(verbatim: model.appName(session.bundleID))
                        .font(.caption2).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if session.duration != nil {
                PlaybackBar(session: session, model: model)
            }

            HStack(spacing: 26) {
                Button { model.previousTrack(session) } label: { Image(systemName: "backward.fill") }
                Button { model.playPause(session) } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26)
                }
                Button { model.nextTrack(session) } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var artwork: some View {
        Group {
            if let image = model.artwork(for: session) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            // Which app it is, as the iPhone shows it.
            if let icon = model.appIcon(session.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: 6, y: 6)
            }
        }
        .padding([.trailing, .bottom], 6)
        .animation(.easeOut(duration: 0.25), value: model.artwork(for: session) != nil)
    }
}

/// How far through the track, with the time gone and the time left. Drag it to move.
private struct PlaybackBar: View {
    let session: NowPlaying
    let model: IslandModel
    @State private var dragged: Double?

    var body: some View {
        let canSeek = model.canSeek(session)
        TimelineView(.animation(minimumInterval: 0.5, paused: !session.isPlaying || dragged != nil)) { context in
            let fraction = dragged ?? session.progress(at: context.date) ?? 0
            let duration = session.duration ?? 0
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(dragged == nil ? 0.85 : 1))
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                    .frame(height: dragged == nil ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragged = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                            }
                            .onEnded { _ in
                                if let dragged { model.seek(session, to: dragged) }
                                dragged = nil
                            },
                        including: canSeek ? .all : .none
                    )
                    .animation(.easeOut(duration: 0.15), value: dragged == nil)
                }
                .frame(height: 10)

                HStack {
                    Text(verbatim: Self.time(fraction * duration))
                    Spacer()
                    Text(verbatim: "−" + Self.time(max(0, duration - fraction * duration)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// A dot per app; the chosen one is long. Press one to go to it.
private struct PlayerDots: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.sessions) { session in
                let chosen = session.id == (model.selectedID ?? model.sessions.first?.id)
                Capsule()
                    .fill(.white.opacity(chosen ? 0.9 : 0.3))
                    .frame(width: chosen ? 14 : 6, height: 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.selectedID = session.id }
                    }
                    .help(Text(verbatim: model.appName(session.bundleID)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.selectedID)
    }
}

/// The Dock's profile, switched from the island.
private struct DockProfileSwitch: View {
    let dock: DockModel

    var body: some View {
        let name = dock.profiles.first { $0.id == dock.activeProfile }?.name ?? ""
        Button {
            let menu = NSMenu()
            for profile in dock.profiles {
                let item = ClosureMenuItem(title: profile.name) { dock.switchProfile(to: profile.id) }
                item.state = profile.id == dock.activeProfile ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            Label {
                Text(verbatim: name).lineLimit(1)
            } icon: {
                Image(systemName: "dock.rectangle")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.1), in: .capsule)
        }
        .buttonStyle(.plain)
        .help(Text("Dock profile"))
    }
}

/// Keeps the Mac awake from the island, the same switch as in the menu bar.
private struct KeepAwakeToggle: View {
    @State private var isOn = KeepAwake.shared.isOn

    var body: some View {
        Button {
            isOn = isOn ? { KeepAwake.shared.stop(); return false }() : KeepAwake.shared.start(.display)
        } label: {
            Label(isOn ? "Staying awake" : "Keep awake", systemImage: isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((isOn ? Palette.accent : Color.white.opacity(0.1)), in: .capsule)
        }
        .buttonStyle(.plain)
        .onAppear { isOn = KeepAwake.shared.isOn }
    }
}
