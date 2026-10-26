import CleanerCore
import SwiftUI

/// What loads into macOS besides ordinary apps, and what still needs translating.
struct AddOnsView: View {
    @Bindable var store: AddOnStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $store.tab) {
                Text("Extensions").tag(AddOnStore.Tab.extensions)
                Text("Plug-ins").tag(AddOnStore.Tab.plugins)
                if store.isRosettaRelevant {
                    Text("Needs Rosetta").tag(AddOnStore.Tab.rosetta)
                }
                if store.isCloudAvailable {
                    Text("Already in iCloud").tag(AddOnStore.Tab.cloud)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if store.isBusy, !store.loaded.contains(store.tab) {
                BusyView(title: "Looking…")
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("System Add-ons")
        .task(id: store.tab) { await store.load(store.tab) }
    }

    @ViewBuilder private var content: some View {
        switch store.tab {
        case .extensions: extensionList
        case .plugins: pluginList
        case .rosetta: rosettaList
        case .cloud: cloudList
        }
    }

    // MARK: - Extensions

    private var extensionList: some View {
        List {
            Section {
                if store.theirExtensions.isEmpty {
                    Text("Nothing but Apple's own.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.theirExtensions) { item in
                    extensionRow(item, canChange: true)
                }
            } header: {
                Text("From apps you installed")
            } footer: {
                Text("Share sheet entries, widgets, Finder extensions and the like. Turning one off leaves the app alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Part of macOS") {
                ForEach(store.appleExtensions) { item in
                    extensionRow(item, canChange: false)
                }
            }
        }
        .listStyle(.inset)
    }

    private func extensionRow(_ item: AppExtension, canChange: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    if let owner = item.owner {
                        Text(verbatim: owner)
                    }
                    if !item.kind.isEmpty {
                        Text(verbatim: item.kind).lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if canChange {
                Menu {
                    Button("Turn Off") { Task { await store.setExtensionEnabled(false, item) } }
                    Button("Turn On") { Task { await store.setExtensionEnabled(true, item) } }
                    Divider()
                    Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([item.path]) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Plug-ins

    private var pluginList: some View {
        List {
            if store.plugins.isEmpty {
                Text("No plug-ins are installed.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.plugins) { plugin in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: plugin.name).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(plugin.kind)
                            Text(plugin.isPerUser ? "Yours only" : "Everyone on this Mac")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: plugin.size.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
                .contextMenu {
                    Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([plugin.path]) }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Rosetta

    private var rosettaList: some View {
        List {
            Section {
                if store.translated.isEmpty {
                    Text("Everything here is built for this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.translated) { app in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: app.name).lineLimit(1)
                            HStack(spacing: 6) {
                                if let version = app.version {
                                    Text(verbatim: version)
                                }
                                if let used = app.lastUsed {
                                    Text("last opened \(used.formatted(date: .abbreviated, time: .omitted))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: app.size.formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            } footer: {
                Text("These carry no code for this Mac, so macOS translates them as they run: slower, and dependent on Rosetta. A newer version may well be built for Apple silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - iCloud

    private var cloudList: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if store.cloudFiles.isEmpty {
                        Text("Nothing large is kept here as well as in iCloud.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.cloudFiles) { file in
                        HStack(spacing: 10) {
                            CheckButton(
                                state: store.cloudSelection.contains(file.id) ? .all : .none, isEnabled: true
                            ) { store.toggleCloud(file) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                                if let used = file.lastUsed {
                                    Text("last opened \(used.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(verbatim: file.size.formatted(.byteCount(style: .file)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                } footer: {
                    Text("iCloud already holds these. Keeping them here as well is only for speed, and freeing the space removes nothing: the file stays in the Finder and downloads again when opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                if store.cloudFreed > 0 {
                    Text("Freed \(store.cloudFreed.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                }
                Spacer()
                Text("Selected \(store.cloudSelectedSize.formatted(.byteCount(style: .file)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Keep in iCloud Only") { Task { await store.evict() } }
                    .prominentButton()
                    .controlSize(.large)
                    .disabled(store.cloudSelection.isEmpty || store.isBusy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}
