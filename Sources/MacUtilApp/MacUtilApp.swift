import SwiftUI

/// One program, two bundles: UniMacHub itself, and the Dock's helper inside it.
@main
enum UniMacHubMain {
    static func main() {
        if DockAgent.isAgentProcess {
            DockAgent.run()
        } else {
            MacUtilApp.main()
        }
    }
}

struct MacUtilApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
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

/// Quitting and coming back. Closed with ⌘Q, from the Dock or with the window's button,
/// UniMacHub goes on in the background, without its window or Dock icon, so the island,
/// the assistant and reminders stay; only Quit in the menu bar's menu, an update, a change
/// of language, and logging out or shutting down end it.
final class AppLifecycle: NSObject, NSApplicationDelegate {
    @MainActor static var reallyQuitting = false

    @MainActor static func quitCompletely() {
        reallyQuitting = true
        NSApp.terminate(nil)
    }

    @MainActor static var keepsRunning: Bool {
        UserDefaults.standard.object(forKey: Preferences.keepsRunning) as? Bool ?? true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard !Self.reallyQuitting, Self.keepsRunning else { return .terminateNow }
            // Logging out, restarting or shutting down: never in the way.
            if let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason),
               reason.typeCodeValue != 0 {
                return .terminateNow
            }
            for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                window.close()
            }
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { NSApp.setActivationPolicy(.regular) }
        return true
    }
}

