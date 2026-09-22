import SwiftUI

@main
struct MacUtilApp: App {
    @State private var state = AppState()
    @AppStorage(Preferences.showsMenuBar) private var showsMenuBar = true

    var body: some Scene {
        Window("MacUtil", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 860, minHeight: 560)
                .task { await state.selfUpdate.check() }
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

        MenuBarExtra(isInserted: $showsMenuBar) {
            MenuBarView(monitor: state.monitor)
                .environment(state)
        } label: {
            MenuBarLabel(monitor: state.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
