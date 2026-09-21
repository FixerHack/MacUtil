#if DEBUG
    import AppKit

    /// Development aid for scripts/snapshot.sh. Environment variables:
    /// - `MACUTIL_SNAPSHOT_MODULE`: sidebar item to show, by case name.
    /// - `MACUTIL_SNAPSHOT_SCAN`: folder to scan first, `junk`, `security`, or `app:Name` to
    ///   open an app in the Uninstaller (all read-only).
    /// - `MACUTIL_WINDOW_ID_FILE`: where to write the window number for `screencapture -l`.
    /// - `MACUTIL_SNAPSHOT`: PNG path for a self-drawn capture, used without Screen
    ///   Recording permission (Liquid Glass areas come out blank).
    enum DebugSnapshot {
        static var isActive: Bool {
            ProcessInfo.processInfo.environment["MACUTIL_SNAPSHOT_MODULE"] != nil
        }

        @MainActor
        static func scheduleIfRequested(state: AppState) {
            let environment = ProcessInfo.processInfo.environment
            guard isActive else { return }

            if let name = environment["MACUTIL_SNAPSHOT_MODULE"],
               let module = Module.allCases.first(where: { name == "\($0)" })
            {
                state.selection = module
            }
            switch environment["MACUTIL_SNAPSHOT_SCAN"] {
            case "security":
                Task { await state.security.scan() }
            case let app? where app.hasPrefix("app:"):
                Task {
                    await state.uninstaller.load()
                    state.uninstaller.selectedAppID = state.uninstaller.apps
                        .first { $0.name.localizedCaseInsensitiveContains(app.dropFirst(4)) }?.id
                }
            case "junk":
                Task {
                    await state.systemJunk.scan()
                    await state.developerJunk.scan()
                    if let first = state.systemJunk.categories.first {
                        state.systemJunk.expanded.insert(first.id)
                    }
                }
            case let path?:
                state.scans.scan(URL(filePath: path))
            case nil:
                break
            }

            if let file = environment["MACUTIL_WINDOW_ID_FILE"] {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    let window = NSApp.windows.filter(\.isVisible).max { $0.frame.width < $1.frame.width }
                    try? String(window?.windowNumber ?? 0).write(toFile: file, atomically: true, encoding: .utf8)
                }
            }

            if let path = environment["MACUTIL_SNAPSHOT"] {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Double(environment["MACUTIL_SNAPSHOT_DELAY"] ?? "") ?? 2))
                    guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?
                        .contentView?.superview,
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
                    if environment["MACUTIL_SNAPSHOT_QUIT"] != nil {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
#endif
