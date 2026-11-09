import AppKit
import CleanerCore
import Foundation
import Observation

/// DNS servers, encrypted DNS, development domains and temporary hosts entries.
@MainActor
@Observable
final class DNSStore {
    private(set) var hasLoaded = false
    private(set) var services: [String] = []
    var selectedService: String?
    /// Servers set by hand for the selected service; empty means automatic.
    private(set) var servers: [String] = []
    private(set) var devDomains: [String] = []
    private(set) var devDomainsAnswer = false
    private(set) var overrides: [HostsOverride] = []
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var notice: String?

    @ObservationIgnored private var expiryTimer: Timer?

    init() {
        // Entries whose time is up are taken out while the app runs; that needs the password,
        // so it is asked for at that moment, with a prompt that says why.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.removeExpired() }
        }
    }

    func load() async {
        services = await DNSControl.services()
        if selectedService == nil || !services.contains(selectedService ?? "") {
            selectedService = services.first { $0 == "Wi-Fi" } ?? services.first
        }
        await loadServers()
        devDomains = DevDomains.installedDomains()
        devDomainsAnswer = await answering(devDomains)
        overrides = HostsFile.overrides()
        hasLoaded = true
    }

    func loadServers() async {
        guard let selectedService else { return }
        servers = await DNSControl.servers(for: selectedService)
    }

    var currentPreset: DNSPreset? { DNSPreset.matching(servers) }

    // MARK: - Servers

    func use(_ servers: [String]) async {
        guard let service = selectedService else { return }
        await run { await DNSControl.setServers(servers, for: service) }
        await loadServers()
    }

    /// Servers typed by hand, separated by spaces or commas.
    func useTyped(_ text: String) async -> Bool {
        let list = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init)
        guard !list.isEmpty, list.allSatisfy(DNSControl.isAddress) else {
            problem = String(localized: "Each server has to be an IP address, such as 1.1.1.1.")
            return false
        }
        await use(list)
        return true
    }

    func flushCache() async {
        await run {
            await AdminRunner.run(
                DNSControl.flushCommands,
                prompt: String(localized: "UniMacHub needs your password to flush the DNS cache.")
            )
        }
        if problem == nil { notice = String(localized: "The DNS cache was flushed.") }
    }

    /// Saves the profile and hands it to macOS, which shows it in System Settings to approve.
    func offerEncryptedProfile(_ preset: DNSPreset) {
        let folder = AppPaths.support.appending(path: "Profiles")
        let file = folder.appending(path: "UniMacHub DNS \(preset.name).mobileconfig")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DNSControl.encryptedProfile(for: preset).write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
            notice = String(localized: "The profile is waiting in System Settings → General → Device Management. Open it there and press Install.")
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Development domains

    /// The command-line tool inside the app, which the login agent runs.
    private var tool: String? {
        Bundle.main.url(forResource: "mucli", withExtension: nil)?.path
    }

    func setDevDomains(_ domains: [String]) async {
        guard let tool else {
            problem = String(localized: "The resolver that answers for these domains is missing from the app. Reinstall UniMacHub.")
            return
        }
        await run { await DevDomains.install(domains) }
        guard problem == nil else { return }
        if !(await DevDomains.startAgent(tool: tool, domains: domains)) {
            problem = String(localized: "The resolver did not start.")
        }
        try? await Task.sleep(for: .milliseconds(500))
        devDomains = DevDomains.installedDomains()
        devDomainsAnswer = await answering(domains)
    }

    /// Whether the resolver answers for the first of these domains; false when there are none.
    private func answering(_ domains: [String]) async -> Bool {
        guard let first = domains.first else { return false }
        return await DevDomains.isAnswering(domain: first)
    }

    func addDevDomain(_ domain: String) async -> Bool {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard DevDomains.isValidDomain(domain) else {
            problem = String(localized: "A domain here is one word, such as test. local and the real endings like com are left alone.")
            return false
        }
        await setDevDomains(Array(Set(devDomains + [domain])).sorted())
        return problem == nil
    }

    func removeDevDomain(_ domain: String) async {
        await setDevDomains(devDomains.filter { $0 != domain })
    }

    // MARK: - Hosts

    func addOverride(hostname: String, address: String, minutes: Int?) async -> Bool {
        let hostname = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        let address = address.trimmingCharacters(in: .whitespaces)
        guard HostsOverride.isValidHostname(hostname) else {
            problem = String(localized: "That is not a name a computer could have.")
            return false
        }
        guard DNSControl.isAddress(address) else {
            problem = String(localized: "The address has to be an IP address, such as 127.0.0.1.")
            return false
        }
        let until = minutes.map { Date(timeIntervalSinceNow: Double($0) * 60) }
        let updated = overrides.filter { $0.hostname != hostname } + [HostsOverride(hostname: hostname, address: address, until: until)]
        return await applyOverrides(updated)
    }

    func removeOverride(_ override: HostsOverride) async {
        await applyOverrides(overrides.filter { $0 != override })
    }

    @discardableResult
    private func applyOverrides(_ updated: [HostsOverride], prompt: String? = nil) async -> Bool {
        await run {
            if let prompt { await HostsFile.apply(updated, prompt: prompt) } else { await HostsFile.apply(updated) }
        }
        overrides = HostsFile.overrides()
        return problem == nil
    }

    func removeExpired() async {
        overrides = HostsFile.overrides()
        guard !busy, overrides.contains(where: { $0.hasExpired() }) else { return }
        await applyOverrides(
            overrides.filter { !$0.hasExpired() },
            prompt: String(localized: "The time is up for a hosts entry UniMacHub added. Your password takes it back out.")
        )
    }

    // MARK: -

    private func run(_ work: () async -> AdminRunner.Output) async {
        busy = true
        problem = nil
        notice = nil
        let output = await work()
        busy = false
        if !output.succeeded, !output.wasCancelled {
            problem = output.text.isEmpty ? String(localized: "That did not work.") : output.text
        }
    }
}
