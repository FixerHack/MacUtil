import AppKit
import CleanerCore
import Foundation
import Observation
import Security

/// The vaults this Mac knows about, and locking them when it is time.
///
/// Locking happens on sleep, on the screen locking, when the drive a vault lives on goes
/// away, and after a stretch with nobody at the Mac — all while UniMacHub is running, which
/// with the menu bar item on is all the time. A vault forgotten here is only forgotten:
/// the file stays where it is.
@MainActor
@Observable
final class VaultStore {
    struct Entry: Identifiable, Hashable {
        let path: String
        var mountPoint: String?

        var id: String { path }
        var name: String { (URL(filePath: path).lastPathComponent as NSString).deletingPathExtension }
        var isOpen: Bool { mountPoint != nil }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    enum Keys {
        static let paths = "vaultPaths"
        static let lockOnSleep = "vaultLockOnSleep"
        static let lockOnScreenLock = "vaultLockOnScreenLock"
        static let idleMinutes = "vaultIdleMinutes"
    }

    private(set) var vaults: [Entry] = []
    private(set) var busy: String?
    private(set) var problem: String?

    var lockOnSleep: Bool {
        didSet { UserDefaults.standard.set(lockOnSleep, forKey: Keys.lockOnSleep) }
    }

    var lockOnScreenLock: Bool {
        didSet { UserDefaults.standard.set(lockOnScreenLock, forKey: Keys.lockOnScreenLock) }
    }

    /// Minutes without a key press or a mouse move before every vault locks; 0 for never.
    var idleMinutes: Int {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: Keys.idleMinutes) }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var idleTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.lockOnSleep: true, Keys.lockOnScreenLock: true, Keys.idleMinutes: 15])
        lockOnSleep = defaults.bool(forKey: Keys.lockOnSleep)
        lockOnScreenLock = defaults.bool(forKey: Keys.lockOnScreenLock)
        idleMinutes = defaults.integer(forKey: Keys.idleMinutes)
        vaults = (defaults.stringArray(forKey: Keys.paths) ?? []).map { Entry(path: $0) }
        watch()
    }

    // MARK: - The list

    func refresh() async {
        for index in vaults.indices {
            vaults[index].mountPoint = await Vault.mountPoint(of: vaults[index].path)
        }
    }

    private func remember(_ path: String) {
        guard !vaults.contains(where: { $0.path == path }) else { return }
        vaults.append(Entry(path: path))
        save()
    }

    func forget(_ entry: Entry) {
        vaults.removeAll { $0.path == entry.path }
        VaultPasswords.delete(for: entry.path)
        save()
    }

    private func save() {
        UserDefaults.standard.set(vaults.map(\.path), forKey: Keys.paths)
    }

    /// Adds a vault made elsewhere, or by an earlier copy of this Mac.
    func add(_ url: URL) async {
        remember(url.path)
        await refresh()
    }

    // MARK: - Making, opening, locking

    func create(in folder: URL, name: String, size: Int64, password: String, rememberPassword: Bool) async -> Bool {
        busy = String(localized: "Creating the vault…")
        problem = nil
        defer { busy = nil }
        switch await Vault.create(at: folder.appending(path: name), volumeName: name, size: size, password: password) {
        case let .success(file):
            remember(file.path)
            if rememberPassword { VaultPasswords.save(password, for: file.path) }
            await refresh()
            return true
        case .failure(.alreadyExists):
            problem = String(localized: "A vault with that name is already in the folder.")
        case let .failure(failure):
            problem = describe(failure)
        }
        return false
    }

    /// Whether a password for this vault is in the Keychain, without reading it.
    func hasSavedPassword(_ entry: Entry) -> Bool {
        VaultPasswords.exists(for: entry.path)
    }

    /// Opens with the password given, or with the one in the Keychain when none is.
    @discardableResult
    func open(_ entry: Entry, password: String? = nil, rememberPassword: Bool = false) async -> Bool {
        guard let password = password ?? VaultPasswords.load(for: entry.path) else { return false }
        busy = String(localized: "Opening…")
        problem = nil
        defer { busy = nil }
        switch await Vault.open(entry.path, password: password) {
        case let .success(mountPoint):
            if rememberPassword { VaultPasswords.save(password, for: entry.path) }
            update(entry.path, mountPoint: mountPoint)
            NSWorkspace.shared.open(URL(filePath: mountPoint))
            return true
        case .failure(.wrongPassword):
            problem = String(localized: "That password does not open this vault.")
        case let .failure(failure):
            problem = describe(failure)
        }
        return false
    }

    func lock(_ entry: Entry, force: Bool = false) async {
        if await Vault.close(entry.path, force: force) {
            update(entry.path, mountPoint: nil)
        } else {
            problem = String(localized: "An app still has a file open in the vault. Close it, or lock anyway.")
        }
    }

    /// Locks every open vault, forcing it: these moments do not wait for an app to let go.
    func lockAll() async {
        await refresh()
        for entry in vaults where entry.isOpen {
            await lock(entry, force: true)
        }
    }

    func changePassword(_ entry: Entry, from old: String, to new: String) async -> Bool {
        busy = String(localized: "Changing the password…")
        problem = nil
        defer { busy = nil }
        switch await Vault.changePassword(entry.path, from: old, to: new) {
        case .success:
            if VaultPasswords.exists(for: entry.path) { VaultPasswords.save(new, for: entry.path) }
            return true
        case .failure(.wrongPassword):
            problem = String(localized: "The current password is not right.")
        case let .failure(failure):
            problem = describe(failure)
        }
        return false
    }

    private func update(_ path: String, mountPoint: String?) {
        if let index = vaults.firstIndex(where: { $0.path == path }) {
            vaults[index].mountPoint = mountPoint
        }
    }

    private func describe(_ failure: Vault.Failure) -> String {
        switch failure {
        case .wrongPassword: String(localized: "That password does not open this vault.")
        case .alreadyExists: String(localized: "A vault with that name is already in the folder.")
        case let .failed(text): text.split(separator: "\n").last.map(String.init) ?? text
        }
    }

    // MARK: - When to lock

    private func watch() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lockOnSleep else { return }
                await self.lockAll()
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lockOnScreenLock else { return }
                await self.lockAll()
            }
        })
        // The drive a vault lives on was unplugged: whatever is mounted from it is gone too.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            Task { @MainActor in
                guard let self, let volume else { return }
                for entry in self.vaults where entry.isOpen && entry.path.hasPrefix(volume + "/") {
                    await self.lock(entry, force: true)
                }
            }
        })
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.idleMinutes > 0, self.vaults.contains(where: \.isOpen) else { return }
                let idle = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: CGEventType(rawValue: ~0)!
                )
                if idle >= Double(self.idleMinutes * 60) {
                    await self.lockAll()
                }
            }
        }
    }
}

/// Vault passwords kept in the login keychain, one per vault file, and only when asked to.
enum VaultPasswords {
    private static let service = "com.fixerhack.MacUtil.vault"

    private static func query(_ path: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: path,
        ]
    }

    static func load(for path: String) -> String? {
        var query = query(path)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func exists(for path: String) -> Bool {
        var query = query(path)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ password: String, for path: String) {
        delete(for: path)
        var item = query(path)
        item[kSecAttrLabel as String] = "UniMacHub vault: " + URL(filePath: path).lastPathComponent
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(for path: String) {
        SecItemDelete(query(path) as CFDictionary)
    }
}
