import AppKit
import CleanerCore
import SwiftUI
import UniformTypeIdentifiers

/// Encrypted volumes kept in one file each: make one, open it with a password, lock it.
struct VaultView: View {
    @Bindable var store: VaultStore
    @State private var creating = false
    @State private var unlocking: VaultStore.Entry?
    @State private var changing: VaultStore.Entry?
    @State private var forgetting: VaultStore.Entry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.vaults.isEmpty {
                ContentUnavailableView {
                    Label("No vaults yet", systemImage: "lock.rectangle.stack")
                } description: {
                    Text("A vault is one encrypted file that opens as a disk with your password. Copy it, back it up or carry it on a stick like any file.")
                } actions: {
                    Button("New Vault…") { creating = true }
                        .prominentButton()
                    Button("Add Existing…") { addExisting() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Vault")
        .task { await store.refresh() }
        .toolbar {
            ToolbarItem {
                Button("Add Existing…", systemImage: "plus.rectangle.on.folder") { addExisting() }
            }
            ToolbarItem {
                Button("New Vault…", systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) { NewVaultSheet(store: store) }
        .sheet(item: $unlocking) { entry in UnlockSheet(store: store, entry: entry) }
        .sheet(item: $changing) { entry in ChangePasswordSheet(store: store, entry: entry) }
        .confirmationDialog(
            "Forget this vault?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { entry in
            Button("Forget") { store.forget(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It leaves this list and its saved password leaves the Keychain. The file itself stays where it is.")
        }
        .overlay {
            if let busy = store.busy {
                BusyView(title: LocalizedStringKey(busy))
                    .background(.background.opacity(0.85))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each vault is an ordinary encrypted disk image, AES-256. It opens in Disk Utility on any Mac, with or without UniMacHub. Forget the password and nothing can open it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Toggle("Lock when the Mac sleeps", isOn: $store.lockOnSleep)
                Toggle("Lock when the screen locks", isOn: $store.lockOnScreenLock)
                Picker("Lock when idle", selection: $store.idleMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                .fixedSize()
            }
            .font(.callout)
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List(store.vaults) { entry in
            HStack(spacing: 12) {
                Image(systemName: entry.isOpen ? "lock.open.fill" : "lock.fill")
                    .font(.title2)
                    .foregroundStyle(entry.isOpen ? AnyShapeStyle(.orange) : AnyShapeStyle(Palette.accent))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name).font(.headline)
                    Text(verbatim: FinderActions.abbreviate(entry.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.exists {
                        Text("The file is not there. Its drive may be unplugged.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if entry.isOpen {
                        Text("Open. Anything on this Mac can read it until it is locked.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if entry.isOpen {
                    Button("Show") {
                        if let mountPoint = entry.mountPoint { NSWorkspace.shared.open(URL(filePath: mountPoint)) }
                    }
                    Button("Lock") { Task { await store.lock(entry) } }
                        .prominentButton()
                } else {
                    Button("Open…") {
                        if store.hasSavedPassword(entry) {
                            Task { await store.open(entry) }
                        } else {
                            unlocking = entry
                        }
                    }
                    .prominentButton()
                    .disabled(!entry.exists)
                }
                Menu {
                    Button("Change Password…") { changing = entry }
                        .disabled(entry.isOpen || !entry.exists)
                    Button("Show File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: entry.path)])
                    }
                    .disabled(!entry.exists)
                    if entry.isOpen {
                        Button("Lock Even If Files Are Open") { Task { await store.lock(entry, force: true) } }
                    }
                    Divider()
                    Button("Forget…") { forgetting = entry }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }

    private func addExisting() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sparseimage"), UTType(filenameExtension: "dmg"),
                                     UTType(filenameExtension: "sparsebundle")].compactMap(\.self)
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an encrypted disk image.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.add(url) }
    }
}

/// Name, size, place and password for a new vault.
private struct NewVaultSheet: View {
    let store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = String(localized: "Private")
    @State private var size: Int64 = 1 << 30
    @State private var folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @State private var password = ""
    @State private var repeated = ""
    @State private var remember = false

    private var nameIsValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.contains(":")
    }

    private var canCreate: Bool {
        nameIsValid && password.count >= 8 && password == repeated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Vault").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Grows up to", selection: $size) {
                    Text(verbatim: "500 MB").tag(Int64(500) << 20)
                    Text(verbatim: "1 GB").tag(Int64(1) << 30)
                    Text(verbatim: "5 GB").tag(Int64(5) << 30)
                    Text(verbatim: "20 GB").tag(Int64(20) << 30)
                    Text(verbatim: "100 GB").tag(Int64(100) << 30)
                }
                LabeledContent("Saved in") {
                    HStack {
                        Text(verbatim: FinderActions.abbreviate(folder.path)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                SecureField("Password", text: $password)
                SecureField("Repeat password", text: $repeated)
                Toggle("Keep the password in the Keychain", isOn: $remember)
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 4) {
                Text("The file starts small and grows as you fill it, up to the size chosen.")
                if !password.isEmpty, password.count < 8 {
                    Text("At least eight characters.").foregroundStyle(.orange)
                } else if !repeated.isEmpty, password != repeated {
                    Text("The two passwords are not the same.").foregroundStyle(.orange)
                }
                Text("If the password is lost, so is everything inside. There is no way back in, by design.")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    Task {
                        if await store.create(
                            in: folder, name: name.trimmingCharacters(in: .whitespaces), size: size,
                            password: password, rememberPassword: remember
                        ) {
                            dismiss()
                        }
                    }
                }
                .prominentButton()
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
            if let problem = store.problem {
                Text(verbatim: problem).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

/// The password, once, to open a vault.
private struct UnlockSheet: View {
    let store: VaultStore
    let entry: VaultStore.Entry
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: entry.name).font(.title3.bold())
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(Palette.accent)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
            Toggle("Keep the password in the Keychain", isOn: $remember)
            if let problem = store.problem {
                Text(verbatim: problem).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Open", action: open)
                    .prominentButton()
                    .disabled(password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func open() {
        guard !password.isEmpty else { return }
        Task {
            if await store.open(entry, password: password, rememberPassword: remember) { dismiss() }
        }
    }
}

private struct ChangePasswordSheet: View {
    let store: VaultStore
    let entry: VaultStore.Entry
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change the password of \(entry.name)").font(.title3.bold())
            SecureField("Current password", text: $current)
            SecureField("New password", text: $new)
            SecureField("Repeat new password", text: $repeated)
            Text("A copy of this file made before the change still opens with the old password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = store.problem {
                Text(verbatim: problem).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Change") {
                    Task { if await store.changePassword(entry, from: current, to: new) { dismiss() } }
                }
                .prominentButton()
                .disabled(current.isEmpty || new.count < 8 || new != repeated)
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 400)
    }
}
