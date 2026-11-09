import AppKit
import CleanerCore
import SwiftUI

/// The island itself: black like the notch it grows out of, wider when it has something to say.
struct IslandView: View {
    let model: IslandModel
    let state: AppState

    private var expanded: Bool { model.presentation == .expanded }

    var body: some View {
        ZStack(alignment: .top) {
            IslandShape(radius: expanded ? 26 : 12)
                .fill(.black)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 6)

            switch model.presentation {
            case .collapsed:
                EmptyView()
            case .wings:
                wings
                    .transition(.opacity)
            case .expanded:
                IslandPanel(model: model, state: state)
                    .padding(.top, 34)
                    .padding([.horizontal, .bottom], 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.presentation)
        .animation(.easeOut(duration: 0.15), value: model.indicator)
        .contentShape(IslandShape(radius: 12))
        .onTapGesture { model.toggle() }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.showsShelf else { return false }
            model.addToShelf(urls)
            return true
        } isTargeted: { model.isDropTargeted = $0 }
    }

    /// One thing either side of the notch: the indicator, the work in hand, or the music.
    @ViewBuilder private var wings: some View {
        HStack(spacing: 0) {
            Group {
                if let indicator = model.indicator {
                    Image(systemName: symbol(for: indicator))
                } else if let work = model.work {
                    ProgressView().controlSize(.small).tint(.white)
                        .help(Text(verbatim: work.title))
                } else if let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: 20, height: 20).clipShape(.rect(cornerRadius: 5))
                } else {
                    Image(systemName: "music.note")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(width: IslandGeometry.wingWidth, alignment: .center)

            Spacer(minLength: 0)

            Group {
                if let indicator = model.indicator {
                    LevelBar(level: indicator.muted ? 0 : indicator.level)
                        .frame(width: 56, height: 5)
                } else if let work = model.work {
                    Text(verbatim: work.title).lineLimit(1).font(.caption2)
                } else if model.nowPlaying?.isPlaying == true {
                    PlayingBars()
                }
            }
            .frame(width: IslandGeometry.wingWidth, alignment: .center)
        }
        .frame(maxHeight: .infinity)
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

/// The notch's own shape: square at the top edge, rounded where it meets the screen below.
struct IslandShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0
        ))
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

/// Three bars that rise and fall while music plays. Only drawn while it plays, so they
/// never keep redrawing a quiet screen.
private struct PlayingBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0 ..< 3, id: \.self) { index in
                    Capsule()
                        .fill(Palette.accentLight)
                        .frame(width: 3, height: 5 + 8 * abs(sin(time * 3.1 + Double(index) * 1.3)))
                }
            }
            .frame(height: 14)
        }
    }
}

/// The opened island: the music, the shelf, and this Mac.
private struct IslandPanel: View {
    let model: IslandModel
    let state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.showsNowPlaying {
                music.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.showsShelf {
                shelf.frame(maxWidth: .infinity)
            }
            mac.frame(width: 140, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var music: some View {
        if let playing = model.nowPlaying {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let artwork = model.artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: playing.player == .spotify ? "music.note.list" : "music.note")
                            .font(.title)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.08))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: playing.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(verbatim: playing.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    HStack(spacing: 14) {
                        Button { model.previousTrack() } label: { Image(systemName: "backward.fill") }
                        Button { model.playPause() } label: {
                            Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        }
                        Button { model.nextTrack() } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.4))
                Text("Nothing playing in Music or Spotify")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shelf: some View {
        VStack(spacing: 6) {
            if model.shelf.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title2)
                    Text("Drop files here to keep them to hand")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(model.isDropTargeted ? 0.9 : 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.white.opacity(model.isDropTargeted ? 0.7 : 0.2))
                )
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
                        }
                    }
                }
                .scrollIndicators(.never)
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
        VStack(alignment: .leading, spacing: 8) {
            KeepAwakeToggle()
            if let work = model.work {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(verbatim: work.title).font(.caption).lineLimit(2)
                }
            }
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
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
