import CleanerCore
import SwiftUI

/// What an app is built on, as a small tag beside its name.
struct RuntimeBadge: View {
    let runtime: AppRuntime

    var body: some View {
        Badge(title: runtime.kind.title, color: runtime.isOutdated() ? .orange : runtime.kind.color)
            .help(runtime.explanation)
    }
}

extension AppRuntime.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .electron: "Electron"
        case .tauri: "Tauri"
        case .flutter: "Flutter"
        case .catalyst: "Catalyst"
        case .iOS: "iPhone app"
        }
    }

    var color: Color {
        switch self {
        case .electron: .purple
        case .tauri: .teal
        case .flutter: .cyan
        case .catalyst, .iOS: .gray
        }
    }
}

extension AppRuntime {
    /// One sentence on what it means for the app to be built this way.
    var explanation: LocalizedStringKey {
        switch kind {
        case .electron:
            if let major = majorVersion, isOutdated() {
                "Electron \(version ?? String(major)), about \(ElectronReleases.releasesBehind(major)) versions behind the newest: too old to get Chromium's security fixes. Updating the app usually brings a newer one."
            } else if let version {
                "Built on Electron \(version), which carries a whole copy of Chromium inside the app."
            } else {
                "Built on Electron, which carries a whole copy of Chromium inside the app."
            }
        case .tauri:
            "Built on Tauri: a web interface drawn with the Safari engine macOS already has."
        case .flutter:
            "Built with Flutter, which draws its own interface instead of using the Mac's."
        case .catalyst:
            "An iPad app brought to the Mac with Catalyst."
        case .iOS:
            "An iPhone or iPad app running on this Mac as it is."
        }
    }
}
