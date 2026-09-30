import CleanerCore
import SwiftUI

/// Disks, partitions and volumes, with the work you can do on them.
struct DisksView: View {
    @Bindable var store: DisksStore
    @State private var erasing: StorageVolume?
    @State private var renaming: StorageVolume?
    @State private var addingVolume: String?
    @State private var newName = ""
    @State private var newFormat = DiskFormat.apfs

    var body: some View {
        VStack(spacing: 0) {
            if store.loading, store.disks.isEmpty {
                BusyView(title: "Looking at your disks…")
            } else {
                HSplitView {
                    diskList.frame(minWidth: 320)
                    detail.frame(minWidth: 380)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Disk Utilities")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
            }
        }
        .task { await store.load() }
        .sheet(item: $erasing) { volume in
            EraseSheet(volume: volume, store: store)
        }
        .sheet(item: $renaming) { volume in
            NameSheet(
                title: String(localized: "Rename \(volume.name)"),
                action: String(localized: "Rename"), name: volume.name
            ) { name in
                Task { await store.rename(volume, to: name) }
            }
        }
        .sheet(isPresented: Binding(get: { addingVolume != nil }, set: { if !$0 { addingVolume = nil } })) {
            NameSheet(
                title: String(localized: "New APFS volume"),
                action: String(localized: "Add"), name: "",
                note: String(localized: "The volume shares the free space of its container, so nothing is resized.")
            ) { name in
                if let container = addingVolume {
                    Task { await store.addVolume(container: container, name: name, quota: nil) }
                }
            }
        }
    }

    private var diskList: some View {
        List(selection: $store.selection) {
            ForEach(store.disks) { disk in
                Section {
                    ForEach(disk.partitions) { partition in
                        if partition.volumes.isEmpty {
                            PartitionRow(partition: partition)
                        } else {
                            ForEach(partition.volumes) { volume in
                                VolumeRow(volume: volume).tag(volume.id)
                            }
                        }
                    }
                } header: {
                    DiskHeader(disk: disk).tag(disk.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let job = store.job {
                    JobCard(job: job) { store.dismissJob() }
                }
                if let volume = store.selectedVolume {
                    VolumeDetail(
                        volume: volume, disk: store.selectedDisk, store: store,
                        erase: { erasing = volume }, rename: { renaming = volume },
                        addVolume: { addingVolume = volume.containerID }
                    )
                } else if let disk = store.selectedDisk {
                    DiskDetail(disk: disk, store: store)
                } else {
                    ContentUnavailableView(
                        "Pick a disk or a volume", systemImage: "internaldrive",
                        description: Text("MacUtil shows what it is, how full it is and what can be done with it.")
                    )
                }
                LeftoversCard(store: store)
                if !store.snapshots.isEmpty {
                    SnapshotsCard(store: store)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DiskHeader: View {
    let disk: StorageDisk

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: disk.isDiskImage ? "doc.badge.gearshape" : disk.isInternal ? "internaldrive" : "externaldrive")
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: disk.model).font(.headline)
                Text(verbatim: "\(disk.id) · \(disk.size.formatted(.byteCount(style: .file)))\(disk.bus.isEmpty ? "" : " · \(disk.bus)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if disk.isStartupDisk {
                Badge(title: "Startup", color: .blue)
            }
            if !disk.healthIsGood {
                Badge(title: "Health", color: .red)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct VolumeRow: View {
    let volume: StorageVolume

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isMounted ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(volume.isMounted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: volume.name.isEmpty ? volume.id : volume.name).lineLimit(1)
                    if volume.isEncrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Gauge(value: min(max(volume.usedFraction, 0), 1)) {}
                    .gaugeStyle(.linearCapacity)
                    .tint(volume.usedFraction > 0.9 ? .orange : .accentColor)
                Text("\(volume.used.formatted(.byteCount(style: .file))) of \(volume.size.formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }
}

private struct PartitionRow: View {
    let partition: StoragePartition

    var body: some View {
        HStack {
            Image(systemName: "square.dashed").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: partition.name ?? partition.id)
                Text(verbatim: "\(DiskInventory.fileSystemName(partition.content)) · \(partition.size.formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct VolumeDetail: View {
    let volume: StorageVolume
    let disk: StorageDisk?
    let store: DisksStore
    let erase: () -> Void
    let rename: () -> Void
    let addVolume: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: volume.name.isEmpty ? volume.id : volume.name).font(.title2.bold())
                Text(verbatim: "\(volume.fileSystem) · \(volume.id)\(volume.mountPoint.map { " · \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
                if volume.isSystemOwned {
                    Label("Part of macOS. MacUtil only reads this one.", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Used").foregroundStyle(.secondary)
                    Text("\(volume.used.formatted(.byteCount(style: .file))) of \(volume.size.formatted(.byteCount(style: .file)))")
                }
                GridRow {
                    Text("Free").foregroundStyle(.secondary)
                    Text(verbatim: volume.free.formatted(.byteCount(style: .file)))
                }
                if !volume.roles.isEmpty {
                    GridRow {
                        Text("Role").foregroundStyle(.secondary)
                        Text(verbatim: volume.roles.joined(separator: ", "))
                    }
                }
                GridRow {
                    Text("Encrypted").foregroundStyle(.secondary)
                    Text(volume.isEncrypted ? "Yes" : "No")
                }
            }
            .font(.callout)
            .monospacedDigit()

            speed

            HStack(spacing: 10) {
                if volume.isMounted {
                    Button("Unmount") { Task { await store.unmount(volume) } }
                        .disabled(volume.isSystemOwned)
                } else {
                    Button("Mount") { Task { await store.mount(volume) } }
                }
                Button("Rename…", action: rename).disabled(volume.isSystemOwned)
                Button("Check") { Task { await store.verify(volume) } }
                Button("Repair") { Task { await store.repair(volume) } }
                    .disabled(volume.isStartup)
                Spacer(minLength: 0)
            }
            .fixedSize()
            HStack(spacing: 10) {
                Button("Erase…", action: erase)
                    .disabled(volume.isSystemOwned)
                if volume.containerID != nil {
                    Button("Add Volume…", action: addVolume)
                    Button("Delete Volume…", role: .destructive) { confirmingDelete = true }
                        .disabled(volume.isSystemOwned)
                }
                if volume.isMounted {
                    Button("Measure Speed") { Task { await store.measureSpeed(of: volume) } }
                        .disabled(store.benchmarkProgress != nil)
                }
                Spacer(minLength: 0)
            }
            .fixedSize()
            .confirmationDialog("Delete the volume \(volume.name)?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { Task { await store.deleteVolume(volume) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything on it is removed and the space goes back to the container. This cannot be undone.")
            }
        }
    }

    @ViewBuilder private var speed: some View {
        if let progress = store.benchmarkProgress {
            VStack(alignment: .leading, spacing: 4) {
                Text("Measuring speed…")
                ProgressView(value: progress).frame(maxWidth: 260)
            }
        } else if let result = store.benchmark {
            HStack(spacing: 18) {
                Label(
                    "Write \(Int64(result.write).formatted(.byteCount(style: .file)))/s",
                    systemImage: "arrow.down.to.line"
                )
                Label(
                    "Read \(Int64(result.read).formatted(.byteCount(style: .file)))/s",
                    systemImage: "arrow.up.to.line"
                )
            }
            .font(.callout)
            .monospacedDigit()
        }
    }
}

private struct DiskDetail: View {
    let disk: StorageDisk
    let store: DisksStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: disk.model).font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(verbatim: disk.size.formatted(.byteCount(style: .file)))
                }
                GridRow {
                    Text("Connection").foregroundStyle(.secondary)
                    Text(verbatim: disk.bus.isEmpty ? disk.id : disk.bus)
                }
                GridRow {
                    Text("Kind").foregroundStyle(.secondary)
                    Text(verbatim: [
                        disk.isInternal ? String(localized: "Internal") : String(localized: "External"),
                        disk.isSolidState ? "SSD" : String(localized: "Hard drive"),
                        disk.isDiskImage ? String(localized: "Disk image") : nil,
                    ].compactMap { $0 }.joined(separator: " · "))
                }
                if let smart = disk.smart {
                    GridRow {
                        Text("Health").foregroundStyle(.secondary)
                        Text(verbatim: smart).foregroundStyle(disk.healthIsGood ? Color.primary : Color.red)
                    }
                }
                if let scheme = disk.partitionScheme {
                    GridRow {
                        Text("Partition map").foregroundStyle(.secondary)
                        Text(verbatim: scheme)
                    }
                }
            }
            .font(.callout)

            if !disk.isStartupDisk {
                Button("Eject") { Task { await store.eject(disk) } }
            }
        }
    }
}

/// Shows the command that ran and what it said, so nothing happens invisibly.
private struct JobCard: View {
    let job: DisksStore.Job
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if job.succeeded == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: job.succeeded == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(job.succeeded == true ? .green : .orange)
                }
                Text(verbatim: job.title).font(.headline)
                Spacer()
                if job.succeeded != nil {
                    Button("Done", action: dismiss)
                }
            }
            if let command = job.command {
                Text(verbatim: command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let output = job.output, !output.isEmpty {
                ScrollView {
                    Text(verbatim: output)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}

/// What macOS keeps after updating itself: downloaded installers, working files and old copies
/// of the system. All of it belongs to root, so removing anything asks for a password.
private struct LeftoversCard: View {
    let store: DisksStore
    @State private var confirming: SystemLeftover?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What macOS left after updating").font(.headline)
                Spacer()
                if store.scanningLeftovers {
                    ProgressView().controlSize(.small)
                } else {
                    Button(store.leftovers.isEmpty ? "Look" : "Look Again") {
                        Task { await store.findLeftovers() }
                    }
                }
            }
            if store.leftovers.isEmpty, !store.scanningLeftovers {
                Text("Installers of updates that are done, working files of a prepared update, copies of the system taken before updating, and the sleep image. The copy your Mac runs from and the recovery system are never offered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(store.leftovers) { leftover in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: leftover.title).font(.callout.weight(.medium))
                            if leftover.size > 0 {
                                Text(verbatim: leftover.size.formatted(.byteCount(style: .file)))
                                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Text(verbatim: leftover.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    Button("Remove…") { confirming = leftover }
                }
                Divider()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .confirmationDialog(
            "Remove \(confirming?.title ?? "")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let leftover = confirming { Task { await store.remove(leftover) } }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(verbatim: confirming?.detail ?? "")
        }
    }
}

private struct SnapshotsCard: View {
    let store: DisksStore
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.snapshots) { snapshot in
                    HStack {
                        Text(verbatim: snapshot.date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.name)
                        Spacer()
                        Button("Delete") { Task { await store.deleteSnapshot(snapshot) } }
                    }
                    .font(.callout)
                }
                Text("Local snapshots hold on to disk space until macOS needs it. Backups on a Time Machine disk are not touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Text("Local snapshots: \(store.snapshots.count)").font(.headline)
        }
    }
}

private struct EraseSheet: View {
    let volume: StorageVolume
    let store: DisksStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var format: DiskFormat
    @State private var confirmation = ""

    init(volume: StorageVolume, store: DisksStore) {
        self.volume = volume
        self.store = store
        _name = State(initialValue: volume.name)
        _format = State(initialValue: DiskOperations.formats(for: volume).first ?? .apfs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Erase \(volume.name)").font(.title3.bold())
            Label(
                "Everything on this volume is deleted. There is no undo, and MacUtil cannot bring the files back afterwards.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $name)
            Picker("Format", selection: $format) {
                ForEach(DiskOperations.formats(for: volume)) { option in
                    Text(verbatim: option.rawValue).tag(option)
                }
            }
            Text(verbatim: format.summary).font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Type the volume's name to confirm:")
                TextField(volume.name, text: $confirmation)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Erase", role: .destructive) {
                    Task { await store.erase(volume, format: format, name: name) }
                    dismiss()
                }
                .disabled(confirmation != volume.name || name.isEmpty)
                .prominentButton()
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct NameSheet: View {
    let title: String
    let action: String
    @State var name: String
    var note: String?
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.title3.bold())
            TextField("Name", text: $name)
            if let note {
                Text(verbatim: note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action) {
                    done(name)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .prominentButton()
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
