import SwiftUI

/// A slice of the ring, cut from a disc.
///
/// Rounded ends are added by the view, which strokes this same shape with a round join on
/// top of filling it. Stroking an arc along its middle instead looked right in principle and
/// wrong on screen: at eight segments the round cap is as long as the slice, so the ring
/// closed into one solid band.
struct AnnularSector: Shape, Equatable {
    /// Degrees, measured from straight up and going clockwise.
    var start: Double
    var sweep: Double
    var inner: Double
    var outer: Double
    /// Degrees shaved off each end, so neighbours stand apart.
    var gap: Double = 3.0

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let from = Angle.degrees(start - 90 + gap)
        let to = Angle.degrees(start + sweep - 90 - gap)

        var path = Path()
        path.addArc(center: centre, radius: radius * outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: centre, radius: radius * inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }
}


/// The main menu as a ring: the hub in the middle, what it leads to around it.
///
/// Two levels and no more. The outer ring shows the sections; choosing one turns the ring
/// over to that section's screens, and the middle goes back. Deeper than that and a circle
/// stops being easier to read than a list — which is still there in the sidebar for anyone
/// who would rather point straight at a name.
struct RadialMenu: View {
    /// The section being shown, or nil while the sections themselves are.
    @Binding var opened: SidebarSection?
    let select: (Module) -> Void

    @State private var hovered: Int?
    @Namespace private var ring

    private var entries: [(title: LocalizedStringKey, symbol: String, planned: Bool)] {
        if let opened {
            opened.modules.map { ($0.title, $0.symbol, $0.isPlanned) }
        } else {
            SidebarSection.allCases.map { ($0.title, $0.symbol, false) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    segment(index: index, entry: entry, side: side, centre: centre)
                }
                core(side: side)
                    .position(centre)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: opened)
    }

    // MARK: - Pieces

    private var count: Int { max(entries.count, 1) }
    private var sweep: Double { 360 / Double(count) }
    private let inner = 0.38
    private let outer = 0.92

    private func segment(
        index: Int, entry: (title: LocalizedStringKey, symbol: String, planned: Bool),
        side: CGFloat, centre: CGPoint
    ) -> some View {
        let start = Double(index) * sweep
        let shape = AnnularSector(start: start, sweep: sweep, inner: inner, outer: outer)
        let isHovered = hovered == index
        let middle = Angle.degrees(start + sweep / 2 - 90)
        let radius = side / 2 * (inner + outer) / 2
        let label = CGPoint(
            x: centre.x + cos(middle.radians) * radius,
            y: centre.y + sin(middle.radians) * radius
        )

        return ZStack {
            shape
                // Filled and stroked with the same colour: the round join rounds the
                // corners outwards, which a fill alone cannot do.
                .stroke(
                    fill(isHovered: isHovered, planned: entry.planned),
                    style: StrokeStyle(lineWidth: side * 0.022, lineCap: .round, lineJoin: .round)
                )
                .background(shape.fill(fill(isHovered: isHovered, planned: entry.planned)))
                .overlay(shape.stroke(.white.opacity(isHovered ? 0.3 : 0.1), lineWidth: 1))
                .shadow(color: .accentColor.opacity(isHovered ? 0.35 : 0), radius: 16)
                .frame(width: side, height: side)
                .position(centre)
                .contentShape(shape)
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                .onTapGesture { choose(index) }

            VStack(spacing: 5) {
                Image(systemName: entry.symbol)
                    .font(.system(size: side * 0.045, weight: .light))
                Text(entry.title)
                    .font(.system(size: side * 0.024, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(entry.planned ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .scaleEffect(isHovered ? 1.08 : 1)
            .position(label)
            .allowsHitTesting(false)
        }
        // Each slice arrives a moment after the one before it, so the ring draws itself.
        .transition(.scale(scale: 0.86).combined(with: .opacity))
        .animation(
            .spring(response: 0.4, dampingFraction: 0.75).delay(Double(index) * 0.022),
            value: opened
        )
    }

    private func fill(isHovered: Bool, planned: Bool) -> some ShapeStyle {
        let base = planned ? Color.secondary : Color.accentColor
        return LinearGradient(
            colors: [
                base.opacity(isHovered ? 0.34 : 0.16),
                base.opacity(isHovered ? 0.18 : 0.07),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func core(side: CGFloat) -> some View {
        Button {
            if opened != nil { opened = nil }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 1)
                VStack(spacing: 3) {
                    if let opened {
                        Image(systemName: "chevron.left")
                            .font(.system(size: side * 0.03, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(opened.title)
                            .font(.system(size: side * 0.028, weight: .semibold))
                    } else {
                        Image(systemName: "circle.hexagongrid")
                            .font(.system(size: side * 0.06, weight: .ultraLight))
                            .foregroundStyle(Color.accentColor)
                        Text(verbatim: "UniMacHub")
                            .font(.system(size: side * 0.024, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(side * 0.02)
            }
            .frame(width: side * inner * 0.92, height: side * inner * 0.92)
        }
        .buttonStyle(.plain)
        .help(opened == nil ? Text("Pick a section") : Text("Back to all sections"))
    }

    private func choose(_ index: Int) {
        if let opened {
            let modules = opened.modules
            guard index < modules.count else { return }
            select(modules[index])
        } else {
            let sections = SidebarSection.allCases
            guard index < sections.count else { return }
            hovered = nil
            opened = sections[index]
        }
    }
}
