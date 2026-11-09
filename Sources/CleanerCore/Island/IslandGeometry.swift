import CoreGraphics

/// Where the island sits on a screen, and how big it is in each state.
///
/// On a Mac with a notch the island grows out of the notch itself: macOS reports the
/// strips of menu bar to either side of it, and the gap between them is the notch. On any
/// other screen it is a small tab at the top in the middle, where the menu bar is empty.
/// Everything here is in screen coordinates with the origin at the bottom left, as AppKit has it.
public struct IslandGeometry: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Resting: the notch, or the tab.
        case collapsed
        /// Showing one thing either side of the notch, such as the volume.
        case wings
        /// Opened by hovering or clicking.
        case expanded
    }

    /// The notch, or nil on a screen without one.
    public let notch: CGRect?
    public let screen: CGRect

    public static let tabSize = CGSize(width: 150, height: 24)
    public static let wingWidth: CGFloat = 96
    public static let expandedSize = CGSize(width: 560, height: 196)

    /// Works the notch out from the screen's frame and the menu bar either side of it.
    public init(screen: CGRect, topInset: CGFloat, leftArea: CGRect?, rightArea: CGRect?) {
        self.screen = screen
        if topInset > 0, let leftArea, let rightArea, rightArea.minX > leftArea.maxX {
            notch = CGRect(
                x: leftArea.maxX, y: screen.maxY - topInset,
                width: rightArea.minX - leftArea.maxX, height: topInset
            )
        } else {
            notch = nil
        }
    }

    public var hasNotch: Bool { notch != nil }

    /// The resting shape: exactly over the notch, or the tab.
    public var resting: CGRect {
        if let notch { return notch }
        return CGRect(
            x: screen.midX - Self.tabSize.width / 2, y: screen.maxY - Self.tabSize.height,
            width: Self.tabSize.width, height: Self.tabSize.height
        )
    }

    /// The frame the island takes in a state, always centred under the top edge.
    public func frame(for state: State) -> CGRect {
        let base = resting
        switch state {
        case .collapsed:
            return base
        case .wings:
            return base.insetBy(dx: -Self.wingWidth, dy: 0)
        case .expanded:
            let size = Self.expandedSize
            return CGRect(
                x: base.midX - size.width / 2, y: screen.maxY - size.height,
                width: size.width, height: size.height
            )
        }
    }
}
