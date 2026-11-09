import CoreGraphics

/// Where everything in the Dock goes, worked out in one place so that what is drawn, what
/// takes clicks and what grows under the pointer can never disagree.
///
/// Positions run along the Dock from the start of the bar as it is laid out with nothing
/// magnified. Lengths are given in icon sizes, so the whole Dock shrinks evenly when it would
/// not fit the screen, the way the system Dock does.
public struct DockLayout: Equatable, Sendable {
    /// One place along the Dock.
    public struct Slot: Equatable, Sendable {
        /// Its length in icon sizes: 1 for an app.
        public var units: CGFloat
        /// Whether it grows under the pointer: icons do, widgets and dividers do not.
        public var grows: Bool

        public init(units: CGFloat, grows: Bool) {
            self.units = units
            self.grows = grows
        }
    }

    /// One place, put somewhere.
    public struct Placed: Equatable, Sendable {
        public var start: CGFloat
        public var length: CGFloat
        public var scale: CGFloat
        public var end: CGFloat { start + length }
        public var centre: CGFloat { start + length / 2 }
    }

    /// Room at each end of the bar, in icon sizes.
    public static let endPadding: CGFloat = 0.14

    /// The icon size used, after shrinking to fit.
    public let icon: CGFloat
    /// The bar's length with nothing magnified.
    public let baseLength: CGFloat
    public let items: [Placed]
    /// The bar as drawn now, magnification included; it can reach past 0 and `baseLength`.
    public let barStart: CGFloat
    public let barEnd: CGFloat
    /// The icon under the pointer, for its name.
    public let hovered: Int?

    /// - Parameters:
    ///   - available: the most room the Dock may take along its edge.
    ///   - pointer: where the pointer is along the unmagnified bar, or nil when it is not on it.
    public init(slots: [Slot], iconSize: CGFloat, available: CGFloat, magnification: CGFloat, pointer: CGFloat?) {
        let units = slots.reduce(0) { $0 + $1.units } + 2 * Self.endPadding
        let icon = max(16, min(iconSize, units > 0 ? available / units : iconSize))
        let padding = Self.endPadding * icon
        self.icon = icon

        // Unmagnified.
        var base: [(start: CGFloat, length: CGFloat)] = []
        var cursor = padding
        for slot in slots {
            base.append((cursor, slot.units * icon))
            cursor += slot.units * icon
        }
        baseLength = cursor + padding

        // Magnified, laid end to end from the start.
        let scales = slots.indices.map { index -> CGFloat in
            guard let pointer, slots[index].grows else { return 1 }
            let centre = base[index].start + base[index].length / 2
            return DockMagnification.scale(distance: pointer - centre, iconSize: icon, magnification: magnification)
        }
        var grown: [(start: CGFloat, length: CGFloat)] = []
        cursor = padding
        for index in slots.indices {
            let length = base[index].length * scales[index]
            grown.append((cursor, length))
            cursor += length
        }
        let grownEnd = cursor + padding

        // The spot under the pointer stays under it: the Dock grows out to both sides of it.
        var shift: CGFloat = 0
        if let pointer, !slots.isEmpty {
            let mapped: CGFloat
            if pointer <= base[0].start {
                mapped = pointer
            } else if let index = base.indices.first(where: { pointer < base[$0].start + base[$0].length }) {
                mapped = grown[index].start + (pointer - base[index].start) * scales[index]
            } else {
                let last = base.count - 1
                mapped = grown[last].start + grown[last].length + (pointer - base[last].start - base[last].length)
            }
            shift = pointer - mapped
        }

        let placed = slots.indices.map { Placed(start: grown[$0].start + shift, length: grown[$0].length, scale: scales[$0]) }
        items = placed
        barStart = shift
        barEnd = grownEnd + shift
        hovered = pointer.flatMap { pointer in
            placed.indices.first { slots[$0].grows && placed[$0].start <= pointer && pointer < placed[$0].end }
        }
    }
}
