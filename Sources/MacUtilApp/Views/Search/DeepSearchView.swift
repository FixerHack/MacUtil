import CleanerCore
import SwiftUI

struct DeepSearchView: View {
    @Bindable var store: SearchStore
    @State private var selection = Set<SearchHit.ID>()
    @State private var sortOrder = [KeyPathComparator(\SearchHit.name)]
    @State private var confirmingTrash = false
    @State private var trashFailures: [CleanupFailure] = []

    private var sortedHits: [SearchHit] {
        store.hits.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)
            filters
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            // One container, so the frame fills it instead of splitting it between
            // the list, divider and footer of a case.
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
        .navigationTitle("Deep Search")
        .confirmationDialog("Move \(selection.count) items to the Trash?", isPresented: $confirmingTrash) {
            Button("Move to Trash") {
                Task {
                    let result = await store.moveToTrash(Array(selection))
                    trashFailures = result.failures
                    selection = []
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Some items could not be moved", isPresented: Binding(
            get: { !trashFailures.isEmpty }, set: {
                if !$0 {
                    trashFailures = []
                }
            }
        )) {
            Button("OK") { trashFailures = [] }
        } message: {
            Text(verbatim: trashFailures.map { "\(FinderActions.abbreviate($0.path)): \($0.reason)" }
                .joined(separator: "\n"))
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField(store.query.searchContents ? "Text inside files" : "File name", text: $store.query.text)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(minWidth: 160, maxWidth: .infinity)
                .onSubmit { Task { await store.run() } }
            Picker("Match", selection: $store.query.matching) {
                Text("Contains").tag(SearchQuery.Matching.contains)
                Text("Wildcard (*.log)").tag(SearchQuery.Matching.wildcard)
                Text("Regular expression").tag(SearchQuery.Matching.regex)
            }
            .labelsHidden()
            .fixedSize()
            if store.isSearching {
                Button("Stop") { store.cancel() }
                    .controlSize(.large)
            } else {
                Button("Search", systemImage: "magnifyingglass") { Task { await store.run() } }
                    .prominentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    Button("Home Folder", systemImage: "house") { store.use(ScanStore.home) }
                    Button("Startup Disk", systemImage: "internaldrive") { store.use(ScanStore.startupDisk) }
                    Divider()
                    Button("Choose Folder…", systemImage: "folder") { store.chooseFolder() }
                } label: {
                    Label { ScanTargetName(url: store.folder) } icon: { Image(systemName: "folder") }
                }
                .fixedSize()

                Picker("Mode", selection: $store.query.mode) {
                    Text("Quick (Spotlight)").tag(SearchQuery.Mode.spotlight)
                    Text("Deep (everything)").tag(SearchQuery.Mode.deep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(
                    "Spotlight is instant but skips ~/Library, hidden and system files. Deep search reads every folder."
                )
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Picker("Kind", selection: $store.query.kind) {
                    Text("All kinds").tag(FileKind?.none)
                    Divider()
                    ForEach(FileKind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(FileKind?.some(kind))
                    }
                }
                .labelsHidden()
                .fixedSize()

                Picker("Modified", selection: $store.age) {
                    Text("Any time").tag(SearchStore.Age.any)
                    Text("Today").tag(SearchStore.Age.day)
                    Text("This week").tag(SearchStore.Age.week)
                    Text("This month").tag(SearchStore.Age.month)
                    Text("This year").tag(SearchStore.Age.year)
                }
                .labelsHidden()
                .fixedSize()

                Toggle("Inside files", isOn: $store.query.searchContents)
                    .help("Look for the text in the contents of files instead of in their names")
                    .fixedSize()
                Toggle("Hidden files", isOn: $store.query.includeHidden)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle:
            ContentUnavailableView {
                Label("Deep Search", systemImage: "magnifyingglass")
            } description: {
                Text("Find files by name, pattern or text inside them, including places Spotlight does not look.")
            }
        case let .failed(message):
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(verbatim: message)
            )
        case .searching where store.hits.isEmpty:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Looked at \(store.progress.examined.formatted()) items…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searching, .ready:
            if store.hits.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass")
            } else {
                resultsTable
            }
        }
    }

    private var resultsTable: some View {
        Table(sortedHits, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { hit in
                Label {
                    Text(verbatim: hit.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: hit.isDirectory ? "folder.fill" : hit.kind.symbol)
                        .foregroundStyle(hit.isDirectory ? Color.accentColor : hit.kind.color)
                }
                .help(hit.path)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Size", value: \.size) { hit in
                Text(verbatim: hit.size.formatted(.byteCount(style: .file))).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modificationDate) { hit in
                Text(hit.modificationDate, format: .dateTime.day(.twoDigits).month(.twoDigits).year())
            }
            .width(min: 90, ideal: 100)
            TableColumn("Location", value: \.directory) { hit in
                Text(verbatim: FinderActions.abbreviate(hit.directory))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 160, ideal: 320)
        }
        .contextMenu(forSelectionType: SearchHit.ID.self) { paths in
            if !paths.isEmpty {
                Button("Open", systemImage: "arrow.up.forward.app") {
                    for path in paths {
                        NSWorkspace.shared.open(URL(filePath: path))
                    }
                }
                Button("Show in Finder", systemImage: "folder") { FinderActions.reveal(Array(paths)) }
                Button("Copy Path", systemImage: "doc.on.clipboard") { FinderActions.copy(Array(paths)) }
                Divider()
                Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                    selection = paths
                    confirmingTrash = true
                }
            }
        } primaryAction: { paths in
            FinderActions.reveal(Array(paths))
        }
    }

    private var statusBar: some View {
        HStack {
            if store.isSearching {
                ProgressView().controlSize(.small)
                Text("Searching… \(store.progress.examined.formatted()) items looked at")
            } else if case .ready = store.phase {
                Text("\(store.hits.count.formatted()) found")
                if let duration = store.duration {
                    Text(verbatim: "· " + duration.formatted(.units(
                        allowed: [.seconds, .milliseconds],
                        width: .abbreviated
                    )))
                }
                if store.hits.count >= DeepSearch.resultLimit {
                    Text("· showing the first \(DeepSearch.resultLimit.formatted())")
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !selection.isEmpty {
                Text("\(selection.count) selected")
                Button("Show in Finder") { FinderActions.reveal(Array(selection)) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}
