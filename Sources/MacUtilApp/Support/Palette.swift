import SwiftUI

/// The colours the app is drawn in.
///
/// One accent, and everything else earns its colour by meaning: orange for something to
/// look at, red for something wrong, green for something settled. A second decorative
/// colour would only make those three harder to notice.
enum Palette {
    static let key = "accentScheme"

    /// The colour families on offer. Blue is the one the app was drawn for; the rest keep
    /// the same weight and brightness so nothing else has to change with them.
    enum Scheme: String, CaseIterable, Identifiable {
        case blue, teal, violet, amber, graphite

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .blue: "Blue"
            case .teal: "Teal"
            case .violet: "Violet"
            case .amber: "Amber"
            case .graphite: "Graphite"
            }
        }

        var accent: Color {
            switch self {
            case .blue: Color(red: 0.23, green: 0.52, blue: 1.0)
            case .teal: Color(red: 0.12, green: 0.70, blue: 0.68)
            case .violet: Color(red: 0.55, green: 0.38, blue: 0.95)
            case .amber: Color(red: 0.95, green: 0.63, blue: 0.18)
            case .graphite: Color(red: 0.52, green: 0.56, blue: 0.62)
            }
        }

        var light: Color {
            switch self {
            case .blue: Color(red: 0.39, green: 0.72, blue: 1.0)
            case .teal: Color(red: 0.35, green: 0.88, blue: 0.84)
            case .violet: Color(red: 0.72, green: 0.58, blue: 1.0)
            case .amber: Color(red: 1.0, green: 0.80, blue: 0.42)
            case .graphite: Color(red: 0.72, green: 0.76, blue: 0.82)
            }
        }
    }

    static var scheme: Scheme {
        Scheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .blue
    }

    /// The colour everything interactive is drawn in.
    static var accent: Color { scheme.accent }
    /// A lighter shade for a gradient's far end, and for glows.
    static var accentLight: Color { scheme.light }
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
