import AppKit
import CleanerCore
import SwiftUI

/// Getting files back: from the Trash, from a snapshot, from a backup, or by reading a disk.
struct RecoveryView: View {
    @Bindable var store: RecoveryStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Where to look", selection: $store.source) {
                Text("Trash").tag(RecoveryStore.Source.trash)
                Text("Snapshots").tag(RecoveryStore.Source.snapshots)
                Text("Time Machine").tag(RecoveryStore.Source.timeMachine)
                Text("Scan a disk").tag(RecoveryStore.Source.scan)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let message = store.message {
                HStack(spacing: 8) {
                    Text(verbatim: message).font(.callout)
                    Spacer()
                    Button("Hide") { store.clearMessage() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            Divider()

            Group {
                switch store.source {
                case .trash: TrashSource(store: store)
                case .snapshots: SnapshotSource(store: store)
                case .timeMachine: TimeMachineSource(store: store)
                case .scan: ScanSource(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("File Recovery")
        .task { await store.load() }
    }

    /// Asks where to put the recovered files.
    static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = title
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct TrashSource: View {
    let store: RecoveryStore

    var body: some View {
        if store.trashItems.isEmpty {
            ContentUnavailableView(
                "The Trash is empty", systemImage: "trash",
                description: Text("Files you delete stay here until the Trash is emptied, and can be put back at any time.")
            )
        } else {
            List {
                ForEach(store.trashItems) { file in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                            .resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: [
                                file.size.formatted(.byteCount(style: .file)),
                                file.modified?.formatted(date: .abbreviated, time: .shortened),
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") {
                            guard let folder = RecoveryView.chooseFolder(
                                title: String(localized: "Where should \(file.name) go?")
                            ) else { return }
                            store.restoreFromTrash(file, to: folder)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct SnapshotSource: View {
    @Bindable var store: RecoveryStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS keeps snapshots of the whole disk when Time Machine is on. A snapshot can be opened for reading, so a file deleted since then can be copied out of it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.snapshots.isEmpty {
                    Label(
                        "There are no snapshots on this Mac. They appear once Time Machine is set up.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                } else {
                    HStack(spacing: 10) {
                        Picker("Snapshot", selection: $store.selectedSnapshot) {
                            ForEach(store.snapshots) { snapshot in
                                Text(verbatim: snapshot.date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.name)
                                    .tag(Optional(snapshot))
                            }
                        }
                        .fixedSize()
                        if store.mountedSnapshot == nil {
                            Button("Open") {
                                guard let snapshot = store.selectedSnapshot else { return }
                                Task { await store.openSnapshot(snapshot) }
                            }
                            .disabled(store.busy)
                        } else {
                            Button("Close") { Task { await store.closeSnapshot() } }
                        }
                    }
                    if store.mountedSnapshot != nil {
                        SearchBar(store: store, placeholder: String(localized: "Name of the lost file"))
                    }
                }
            }
            .padding(20)
            Divider()
            ResultList(store: store)
        }
    }
}

private struct TimeMachineSource: View {
    @Bindable var store: RecoveryStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if !store.hasBackupDisk {
                    Label("No Time Machine disk is set up on this Mac.", systemImage: "externaldrive.badge.questionmark")
                } else if store.backups.isEmpty {
                    Label("Connect the backup disk to see what is on it.", systemImage: "externaldrive")
                } else {
                    Picker("Backup", selection: $store.selectedBackup) {
                        ForEach(store.backups) { backup in
                            Text(verbatim: backup.date?.formatted(date: .abbreviated, time: .shortened) ?? backup.path)
                                .tag(Optional(backup))
                        }
                    }
                    .fixedSize()
                    SearchBar(store: store, placeholder: String(localized: "Name of the lost file"))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ResultList(store: store)
        }
    }
}

private struct SearchBar: View {
    @Bindable var store: RecoveryStore
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $store.search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await store.runSearch() } }
            Button("Search") { Task { await store.runSearch() } }
                .disabled(store.search.count < 2 || store.busy)
            if store.busy {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct ResultList: View {
    let store: RecoveryStore

    var body: some View {
        if store.results.isEmpty {
            ContentUnavailableView(
                "Nothing to show yet", systemImage: "clock.arrow.circlepath",
                description: Text("Search by part of the file's name.")
            )
        } else {
            List {
                ForEach(store.results) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: [
                                file.size.formatted(.byteCount(style: .file)),
                                file.modified?.formatted(date: .abbreviated, time: .shortened),
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") {
                            guard let folder = RecoveryView.chooseFolder(
                                title: String(localized: "Where should \(file.name) go?")
                            ) else { return }
                            Task { await store.restore(file, to: folder) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
    }
}

/// Two ways to get files off a disk: read what its records remember, or read every byte.
private struct ScanSource: View {
    @Bindable var store: RecoveryStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("How to look", selection: $store.scanKind) {
                    Text("By name").tag(RecoveryStore.ScanKind.quick)
                    Text("Byte by byte").tag(RecoveryStore.ScanKind.deep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Text(store.scanKind == .quick
                    ? "Deleting a file on a memory card only clears a flag: its name, size and date stay in the card's records until something writes over them. This reads those records, so files come back with their own names, in seconds."
                    : "Reads every byte of the disk and recognises files by their shape. It finds files the records no longer mention, but it cannot know their names, and a 256 GB card takes hours.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if store.scanKind == .quick {
                    quickControls
                } else {
                    deepControls
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            results
        }
    }

    @ViewBuilder private var quickControls: some View {
        if store.scannableVolumes.isEmpty {
            Label("Connect a memory card, a flash drive or an external disk.", systemImage: "externaldrive.badge.plus")
        } else {
            HStack(spacing: 10) {
                Picker("Volume", selection: $store.selectedVolumeID) {
                    ForEach(store.scannableVolumes) { volume in
                        Text(verbatim: "\(volume.name.isEmpty ? volume.id : volume.name) · \(volume.fileSystem)")
                            .tag(Optional(volume.id))
                    }
                }
                .fixedSize()
                Button("Look for Files") {
                    guard let volume = selectedVolume else { return }
                    Task { await store.quickScan(volume: volume) }
                }
                .prominentButton()
                .disabled(store.busy || selectedVolume == nil)
                if !store.recorded.isEmpty {
                    Button("Restore All…") { restoreAll() }
                }
                if store.busy {
                    ProgressView().controlSize(.small)
                }
            }
            if let failure = store.quickScanFailed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: failure).font(.callout).foregroundStyle(.orange)
                    Text("Only exFAT disks keep records MacUtil can read this way. For anything else, use byte by byte.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var deepControls: some View {
        if store.scannableDisks.isEmpty {
            Label("Connect a memory card, a flash drive or an external disk.", systemImage: "externaldrive.badge.plus")
        } else {
            HStack(spacing: 10) {
                Picker("Disk", selection: $store.selectedDevice) {
                    ForEach(store.scannableDisks) { disk in
                        Text(verbatim: "\(disk.model) · \(disk.size.formatted(.byteCount(style: .file)))")
                            .tag(Optional(disk.id))
                    }
                }
                .fixedSize()
                if store.isScanning {
                    Button("Stop") { store.cancelScan() }
                } else {
                    Button("Scan…") { startDeepScan() }
                        .prominentButton()
                        .disabled(store.selectedDevice == nil)
                }
            }
            Text("A physical disk belongs to macOS itself, so MacUtil asks for your password once to read it. Nothing is written to the disk being scanned.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Every picture is opened after it is read. Whole ones land in the folder you choose; a photo that was written in pieces leaves only its header, so its small preview goes to \"partly recovered\", and what cannot be read at all goes to \"damaged\".")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Recovered files are written to a folder you choose, which must be on another disk. Writing to the disk being scanned would destroy what is left of the lost files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let progress = store.scanProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text("Read \(progress.bytesScanned.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file))) · found \(progress.found)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let rate = store.scanRate {
                        Text("\(rate.speed) · about \(rate.remaining) left")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        if store.scanKind == .quick {
            if store.recorded.isEmpty {
                ContentUnavailableView(
                    "Nothing found yet", systemImage: "doc.text.magnifyingglass",
                    description: Text("Pick a card and look for files. Deleted files keep their names until something writes over them.")
                )
            } else {
                List {
                    ForEach(store.recorded) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.badge.arrow.up").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                                Text(verbatim: [
                                    file.folder.isEmpty ? nil : file.folder,
                                    file.size.formatted(.byteCount(style: .file)),
                                    file.modified?.formatted(date: .abbreviated, time: .shortened),
                                ].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !file.isContiguous {
                                Badge(title: "In pieces", color: .orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        } else if store.carved.isEmpty {
            ContentUnavailableView(
                "Nothing recovered yet", systemImage: "doc.viewfinder",
                description: Text("Pick a disk and start the scan. Photos, documents, archives, video and databases are recognised.")
            )
        } else {
            List {
                ForEach(store.carved) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.quality == .whole ? "doc.badge.arrow.up" : "exclamationmark.triangle")
                            .foregroundStyle(file.quality == .whole ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: file.signature)
                            Text(verbatim: "\(file.size.formatted(.byteCount(style: .file))) · \(file.suggestedName)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        switch file.quality {
                        case .whole: EmptyView()
                        case .partial: Badge(title: "Preview only", color: .orange)
                        case .damaged: Badge(title: "Does not open", color: .red)
                        }
                        if let path = file.recoveredTo {
                            Button("Show in Finder") { FinderActions.reveal([path]) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
    }

    private var selectedVolume: StorageVolume? {
        store.scannableVolumes.first { $0.id == store.selectedVolumeID }
    }

    private func restoreAll() {
        guard let volume = selectedVolume,
              let folder = RecoveryView.chooseFolder(
                  title: String(localized: "Choose a folder on another disk for the recovered files")
              )
        else { return }
        Task { await store.restoreAll(volume: volume, to: folder) }
    }

    private func startDeepScan() {
        guard let device = store.selectedDevice,
              let folder = RecoveryView.chooseFolder(
                  title: String(localized: "Choose a folder on another disk for the recovered files")
              )
        else { return }
        store.scan(device: device, output: folder)
    }
}
