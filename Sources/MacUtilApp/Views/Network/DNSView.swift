import AppKit
import CleanerCore
import SwiftUI

/// Where this Mac looks names up, and the names it answers differently on purpose.
struct DNSView: View {
    @Bindable var store: DNSStore
    @State private var typedServers = ""
    @State private var newDomain = ""
    @State private var hostname = ""
    @State private var address = "127.0.0.1"
    @State private var minutes: Int? = 60

    var body: some View {
        Group {
            if !store.hasLoaded {
                BusyView(title: "Reading the network settings…")
            } else {
                Form {
                    messages
                    servers
                    encrypted
                    developmentDomains
                    hostsEntries
                }
                .formStyle(.grouped)
                .disabled(store.busy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("DNS & Domains")
        .task { await store.load() }
        .toolbar {
            ToolbarItem {
                Button("Flush DNS Cache", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await store.flushCache() }
                }
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let problem = store.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        if let notice = store.notice {
            Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    // MARK: - Servers

    private var servers: some View {
        Section {
            Picker("Network service", selection: $store.selectedService) {
                ForEach(store.services, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
            }
            .onChange(of: store.selectedService) { Task { await store.loadServers() } }

            LabeledContent("Now") {
                if store.servers.isEmpty {
                    Text("Automatic, from the network")
                } else if let preset = store.currentPreset {
                    Text(verbatim: preset.name)
                } else {
                    Text(verbatim: store.servers.joined(separator: ", ")).textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                Button("Automatic") { Task { await store.use([]) } }
                    .disabled(store.servers.isEmpty)
                ForEach(DNSPreset.all) { preset in
                    Button(preset.name) { Task { await store.use(preset.servers) } }
                        .disabled(store.currentPreset == preset)
                }
            }

            HStack {
                TextField("Other servers", text: $typedServers, prompt: Text(verbatim: "1.1.1.1, 9.9.9.9"))
                Button("Use") {
                    Task { if await store.useTyped(typedServers) { typedServers = "" } }
                }
                .disabled(typedServers.isEmpty)
            }
        } header: {
            Text("DNS servers")
        } footer: {
            Text("A captive Wi-Fi page in a hotel or café needs the network's own DNS. If one will not load, switch back to Automatic.")
        }
    }

    // MARK: - Encrypted

    private var encrypted: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(DNSPreset.all) { preset in
                    Button(preset.name) { store.offerEncryptedProfile(preset) }
                }
            }
        } header: {
            Text("Encrypted DNS")
        } footer: {
            Text("Plain DNS travels in the open, so the network sees every name you look up. A profile switches the whole Mac to DNS over HTTPS. macOS asks you to approve it in System Settings, and removing it there turns it off.")
        }
    }

    // MARK: - Development domains

    private var developmentDomains: some View {
        Section {
            ForEach(store.devDomains, id: \.self) { domain in
                HStack {
                    Image(systemName: store.devDomainsAnswer ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(store.devDomainsAnswer ? .green : .orange)
                    Text(verbatim: "*.\(domain) → 127.0.0.1")
                        .font(.body.monospaced())
                    Spacer()
                    Button("Remove") { Task { await store.removeDevDomain(domain) } }
                }
            }
            if !store.devDomains.isEmpty, !store.devDomainsAnswer {
                Text("The resolver is not answering yet. Adding the domain again restarts it.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                TextField("Domain", text: $newDomain, prompt: Text(verbatim: "test"))
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .disabled(newDomain.isEmpty)
            }
        } header: {
            Text("Development domains")
        } footer: {
            Text("Every name under the domain, such as app.test or api.shop.test, points at this Mac, so a project can run under a real name instead of a port number. Only these domains are touched; a small resolver of UniMacHub's answers for them on this Mac alone.")
        }
    }

    private func addDomain() {
        let domain = newDomain
        Task { if await store.addDevDomain(domain) { newDomain = "" } }
    }

    // MARK: - Hosts

    private var hostsEntries: some View {
        Section {
            ForEach(store.overrides) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(entry.hostname) → \(entry.address)")
                            .font(.body.monospaced())
                        if let until = entry.until {
                            Text(entry.hasExpired() ? "Time is up; waiting for your password to remove it" : "Until \(until.formatted(date: .omitted, time: .shortened)) \(until.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(entry.hasExpired() ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        } else {
                            Text("Until removed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove") { Task { await store.removeOverride(entry) } }
                }
            }
            HStack {
                TextField("Name", text: $hostname, prompt: Text(verbatim: "api.example.com"))
                TextField("Address", text: $address)
                    .frame(width: 140)
                Picker("For", selection: $minutes) {
                    Text("15 minutes").tag(Int?.some(15))
                    Text("1 hour").tag(Int?.some(60))
                    Text("1 day").tag(Int?.some(1440))
                    Text("Until removed").tag(Int?.none)
                }
                .fixedSize()
                Button("Add") {
                    Task {
                        if await store.addOverride(hostname: hostname, address: address, minutes: minutes) {
                            hostname = ""
                        }
                    }
                }
                .disabled(hostname.isEmpty || address.isEmpty)
            }
        } header: {
            Text("Temporary hosts entries")
        } footer: {
            Text("Points one name somewhere else for a while, to try a new server before switching DNS. Entries go between UniMacHub's markers in /etc/hosts, and nothing else in the file is touched. Taking one out needs your password; when its time is up, UniMacHub asks for it then.")
        }
    }
}
