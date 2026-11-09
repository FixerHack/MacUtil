import SwiftUI

@main
struct MacUtilApp: App {
    @State private var state = AppState()
    @AppStorage(Preferences.showsMenuBar) private var showsMenuBar = true

    var body: some Scene {
        Window("UniMacHub", id: "main") {
            ContentView()
                .environment(state)
                .modifier(MainWindowOpener(state: state))
                .frame(minWidth: 860, minHeight: 560)
                .background(Backdrop())
                .tint(Palette.accent)
                .task { await state.selfUpdate.check() }
                .task { await ScheduledCleanup.runIfDue() }
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

        MenuBarExtra(isInserted: $showsMenuBar) {
            MenuBarView(monitor: state.monitor)
                .environment(state)
        } label: {
            MenuBarLabel(monitor: state.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hands the window-opening action to the app state, for the island and the Dock.
private struct MainWindowOpener: ViewModifier {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            state.openMainWindow = { open(id: "main") }
        }
    }
}
