import SwiftUI

@main
struct MacCleanerApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("MacCleaner", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 860, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // The user may have just granted Full Disk Access or freed space elsewhere.
                    state.refresh()
                }
            #if DEBUG
                .onAppear { DebugSnapshot.scheduleIfRequested(state: state) }
            #endif
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}
