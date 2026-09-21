#if DEBUG
    import AppKit

    /// Development aid: `MACCLEANER_SNAPSHOT=/path/shot.png` makes the app save a PNG
    /// of its main window. `MACCLEANER_SNAPSHOT_MODULE` picks the sidebar item by its
    /// case name and `MACCLEANER_SNAPSHOT_SCAN` starts a scan of that folder. Captures only our own window, so no
    /// Screen Recording permission.
    enum DebugSnapshot {
        @MainActor
        static func scheduleIfRequested(state: AppState) {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["MACCLEANER_SNAPSHOT"] else { return }
            if let name = environment["MACCLEANER_SNAPSHOT_MODULE"],
               let module = Module.allCases.first(where: { name == "\($0)" })
            {
                state.selection = module
            }
            if let scanPath = environment["MACCLEANER_SNAPSHOT_SCAN"] {
                state.scans.scan(URL(filePath: scanPath))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(environment["MACCLEANER_SNAPSHOT_DELAY"] ?? "") ?? 2))
                // cacheDisplay leaves Liquid Glass and scroll views blank; full-fidelity
                // captures need `screencapture -l` with Screen Recording permission.
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView?
                    .superview,
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
                if environment["MACCLEANER_SNAPSHOT_QUIT"] != nil {
                    NSApp.terminate(nil)
                }
            }
        }
    }
#endif
