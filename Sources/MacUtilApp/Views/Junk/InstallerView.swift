import CleanerCore
import SwiftUI

/// Disk images and packages that have already done their job.
struct InstallerView: View {
    @Bindable var store: InstallerStore
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Installer Files")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await store.scan() } }
                    .disabled(store.isBusy)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle:
            ContentUnavailableView {
                Label("Installer Files", systemImage: "shippingbox.and.arrow.backward")
            } description: {
                Text("A disk image or package only carries an app to your Mac. Once the app is in place the carrier is just a large file, and these are often the biggest things in Downloads.")
            } actions: {
                Button("Look for Installers") { Task { await store.scan() } }
                    .prominentButton()
                    .controlSize(.large)
            }
        case .scanning:
            BusyView(title: "Looking through Downloads…")
        case .cleaning:
            BusyView(title: "Moving to Trash…")
        case let .done(result):
            CleanupResultView(result: result) {
                Task { await store.finish() }
            } done: {
                Task { await store.finish() }
            }
        case .ready where store.files.isEmpty:
            ContentUnavailableView(
                "No installers lying around", systemImage: "checkmark.circle",
                description: Text("Nothing to tidy in Downloads, on the Desktop or in Documents.")
            )
        case .ready:
            header
            Divider()
            list
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("\(store.files.count) installers · \(store.totalSize.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            if !store.spent.isEmpty {
                section(
                    store.spent, title: "The app is already installed",
                    note: "Safe to remove: the app is on your Mac, and the installer can be downloaded again."
                )
            }
            if !store.unmatched.isEmpty {
                section(
                    store.unmatched, title: "No matching app found",
                    note: "Either it installs something that is not an app, or you have not installed it yet. Look before removing."
                )
            }
        }
        .listStyle(.inset)
    }

    private func section(
        _ files: [InstallerFile], title: LocalizedStringKey, note: LocalizedStringKey
    ) -> some View {
        Section {
            ForEach(files) { file in
                HStack(spacing: 10) {
                    CheckButton(
                        state: store.selection.contains(file.id) ? .all : .none, isEnabled: true
                    ) { store.toggle(file) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            if let app = file.installedApp {
                                Text("Installed: \(app)")
                            }
                            Text(verbatim: file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: file.size.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        } header: {
            HStack(spacing: 8) {
                Button {
                    store.toggleAll(files)
                } label: {
                    Text(title).font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("Selected \(store.selection.count) · \(store.selectedSize.formatted(.byteCount(style: .file)))")
                .monospacedDigit()
                .font(.headline)
            Spacer()
            Button("Move to Trash…") { confirming = true }
                .prominentButton()
                .controlSize(.large)
                .disabled(store.selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Move \(store.selection.count) installers to the Trash?", isPresented: $confirming
        ) {
            Button("Move to Trash") { Task { await store.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Installed apps are not affected. Anything you need again can be downloaded from its website.")
        }
    }
}
