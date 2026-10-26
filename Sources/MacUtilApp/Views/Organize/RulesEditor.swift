import CleanerCore
import SwiftUI

/// The rules for one watched folder.
struct RulesEditor: View {
    @Bindable var store: OrganizeStore
    let folder: WatchedFolder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                nameRules
                extensionRules
            }
            .listStyle(.inset)
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Toggle("Sort new files as they arrive", isOn: Binding(
                get: { folder.organizesAutomatically },
                set: { value in
                    var updated = folder
                    updated.organizesAutomatically = value
                    store.update(updated)
                }
            ))
            Text("Watching happens only while UniMacHub is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var nameRules: some View {
        Section {
            if folder.nameRules.isEmpty {
                Text("No name rules. Add one to catch things like Invoice* or *Screenshot*.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(folder.nameRules) { rule in
                HStack(spacing: 8) {
                    Toggle("On", isOn: binding(for: rule, \.isEnabled))
                        .labelsHidden()
                    TextField("Pattern", text: binding(for: rule, \.pattern))
                        .frame(maxWidth: 170)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    TextField("Folder", text: binding(for: rule, \.destination))
                    Button("Remove", systemImage: "minus.circle") { remove(rule) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
            }
            Button("Add Name Rule", systemImage: "plus") { store.addNameRule(to: folder) }
                .buttonStyle(.link)
        } header: {
            Text("By name")
        } footer: {
            Text("Checked first, because a name says more than an extension does.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var extensionRules: some View {
        Section {
            ForEach(folder.extensionRules) { rule in
                HStack(spacing: 8) {
                    Toggle("On", isOn: binding(for: rule, \.isEnabled))
                        .labelsHidden()
                    TextField("Extensions", text: binding(for: rule, \.extensions))
                        .frame(maxWidth: 260)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    TextField("Folder", text: binding(for: rule, \.destination))
                    Button("Remove", systemImage: "minus.circle") { remove(rule) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Button("Add Extension Rule", systemImage: "plus") { store.addExtensionRule(to: folder) }
                Button("Add the Ready-Made Set") { store.addPresets(to: folder) }
            }
            .buttonStyle(.link)
        } header: {
            Text("By extension")
        }
    }

    private var footer: some View {
        HStack {
            Button("Stop Watching", role: .destructive) { store.removeFolder(folder) }
            Spacer()
            Button("See What Would Move") { Task { await store.preview() } }
                .prominentButton()
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Editing

    private func binding<Value>(
        for rule: ExtensionRule, _ keyPath: WritableKeyPath<ExtensionRule, Value>
    ) -> Binding<Value> {
        Binding(
            get: { folder.extensionRules.first { $0.id == rule.id }?[keyPath: keyPath] ?? rule[keyPath: keyPath] },
            set: { value in
                var updated = folder
                guard let index = updated.extensionRules.firstIndex(where: { $0.id == rule.id }) else { return }
                updated.extensionRules[index][keyPath: keyPath] = value
                store.update(updated)
            }
        )
    }

    private func binding<Value>(
        for rule: NameRule, _ keyPath: WritableKeyPath<NameRule, Value>
    ) -> Binding<Value> {
        Binding(
            get: { folder.nameRules.first { $0.id == rule.id }?[keyPath: keyPath] ?? rule[keyPath: keyPath] },
            set: { value in
                var updated = folder
                guard let index = updated.nameRules.firstIndex(where: { $0.id == rule.id }) else { return }
                updated.nameRules[index][keyPath: keyPath] = value
                store.update(updated)
            }
        )
    }

    private func remove(_ rule: ExtensionRule) {
        var updated = folder
        updated.extensionRules.removeAll { $0.id == rule.id }
        store.update(updated)
    }

    private func remove(_ rule: NameRule) {
        var updated = folder
        updated.nameRules.removeAll { $0.id == rule.id }
        store.update(updated)
    }
}
