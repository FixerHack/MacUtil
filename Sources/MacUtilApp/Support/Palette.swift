import SwiftUI

/// The colours the app is drawn in.
///
/// One accent, and everything else earns its colour by meaning: orange for something to
/// look at, red for something wrong, green for something settled. A second decorative
/// colour would only make those three harder to notice.
enum Palette {
    /// The blue everything interactive is drawn in.
    static let accent = Color(red: 0.23, green: 0.52, blue: 1.0)
    /// A lighter blue for a gradient's far end, and for glows.
    static let accentLight = Color(red: 0.39, green: 0.72, blue: 1.0)
    /// Deep blue the backdrop fades towards, so the window is not flat grey.
    static let backdrop = Color(red: 0.05, green: 0.08, blue: 0.16)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentLight, accent], startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// The window's own background: a dark field with the faintest blue cast.
///
/// Drawn once behind everything rather than per screen, so moving between tools does not
/// flash a different shade.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(
                colors: [Palette.backdrop.opacity(0.55), .clear],
                center: .top, startRadius: 0, endRadius: 760
            )
        }
        .ignoresSafeArea()
    }
}
