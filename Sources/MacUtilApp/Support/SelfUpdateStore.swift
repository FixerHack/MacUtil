import CleanerCore
import Foundation
import SecurityCore
import SwiftUI

/// Checks GitHub for a newer MacUtil and installs it.
///
/// Nothing is downloaded or installed without the person asking; the automatic part is the check.
@MainActor @Observable final class SelfUpdateStore {
    enum Phase: Equatable {
        case idle
        case checking
        case available(MacUtilRelease)
        case downloading(Double)
        case installing
        /// Installed and waiting to be restarted.
        case installed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var lastError: String?
    /// Set after a check that the person started, so "You are up to date" can be shown.
    private(set) var checkedManually = false

    var release: MacUtilRelease? {
        if case let .available(release) = phase { return release }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// Runs at most once a day unless `manual` is set.
    func check(manual: Bool = false) async {
        guard !isBusy else { return }
        if case .installed = phase { return }
        let defaults = UserDefaults.standard
        if !manual {
            guard defaults.bool(forKey: Preferences.automaticUpdateCheck) else { return }
            let last = defaults.double(forKey: Preferences.lastUpdateCheck)
            guard Date.now.timeIntervalSince1970 - last > 60 * 60 * 24 else { return }
        }

        lastError = nil
        checkedManually = manual
        phase = .checking
        do {
            let release = try await SelfUpdate.check()
            defaults.set(Date.now.timeIntervalSince1970, forKey: Preferences.lastUpdateCheck)
            phase = release.map(Phase.available) ?? .idle
        } catch {
            phase = .idle
            if manual { lastError = error.localizedDescription }
        }
    }

    /// Downloads the release, replaces this copy and leaves the app ready to restart.
    func install() async {
        guard case let .available(release) = phase else { return }
        lastError = nil
        phase = .downloading(0)
        do {
            let dmg = try await SelfUpdate.download(release) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction)
                }
            }
            defer { try? FileManager.default.removeItem(at: dmg) }
            phase = .installing
            let app = try await SelfUpdate.install(dmg: dmg)
            phase = .installed(app.path)
        } catch {
            lastError = error.localizedDescription
            phase = .available(release)
        }
    }

    func restart() {
        guard case let .installed(path) = phase else { return }
        SelfUpdate.relaunch(at: URL(filePath: path))
        NSApp.terminate(nil)
    }

    func dismiss() {
        if case .available = phase { phase = .idle }
        lastError = nil
    }
}
