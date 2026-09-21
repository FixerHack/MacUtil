import CleanerCore
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            ScanHeader()
            Divider()
            if let result = state.scans.result {
                LargeFilesBrowser(result: result)
                    .id(result.id)
            } else {
                ScanPlaceholder(module: .largeFiles)
            }
        }
        .navigationTitle("Large & Old Files")
    }
}

enum SizeThreshold: Int64, CaseIterable, Identifiable {
    case mb10 = 10_000_000
    case mb50 = 50_000_000
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000

    var id: Self { self }
}

enum AgeFilter: Int, CaseIterable, Identifiable {
    case any = 0
    case month = 30
    case threeMonths = 91
    case sixMonths = 182
    case year = 365

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .any: "Any time"
        case .month: "Not opened for a month"
        case .threeMonths: "Not opened for 3 months"
        case .sixMonths: "Not opened for 6 months"
        case .year: "Not opened for a year"
        }
    }

    /// Unix time after which a file counts as recently opened.
    var cutoff: Int64 {
        self == .any ? .max : Int64(Date().timeIntervalSince1970) - Int64(rawValue) * 86400
    }
}

private struct Query: Hashable {
    var minimumSize = SizeThreshold.mb100
    var age = AgeFilter.any
    var kind: FileKind?
    var search = ""
}

private struct LargeFilesBrowser: View {
    let result: ScanResult
    @State private var query = Query()
    @State private var items: [FileItem] = []
    @State private var isSearching = false
    @State private var selection = Set<FileItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\FileItem.allocatedSize, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            filters
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            table
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .task(id: query) {
            await search()
        }
        .onChange(of: sortOrder) { _, order in
            items.sort(using: order)
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Size", selection: $query.minimumSize) {
                ForEach(SizeThreshold.allCases) { threshold in
                    Text("Over \(threshold.rawValue.formatted(.byteCount(style: .file)))").tag(threshold)
                }
            }
            .fixedSize()

            Picker("Last opened", selection: $query.age) {
                ForEach(AgeFilter.allCases) { age in
                    Text(age.title).tag(age)
                }
            }
            .fixedSize()

            Picker("Kind", selection: $query.kind) {
                Text("All kinds").tag(FileKind?.none)
                Divider()
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(FileKind?.some(kind))
                }
            }
            .fixedSize()

            Spacer()

            TextField("Filter by name", text: $query.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 220)
        }
        // The chosen values ("Over 100 MB", "All kinds") explain themselves.
        .labelsHidden()
    }

    private var table: some View {
        Table(items, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label {
                    Text(verbatim: item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(item.kind.color)
                }
                .help(item.path)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Size", value: \.allocatedSize) { item in
                Text(verbatim: item.allocatedSize.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Last Opened", value: \.accessDate) { item in
                Text(item.accessDate, format: .dateTime.day(.twoDigits).month(.twoDigits).year())
            }
            .width(min: 90, ideal: 110)

            TableColumn("Modified", value: \.modificationDate) { item in
                Text(item.modificationDate, format: .dateTime.day(.twoDigits).month(.twoDigits).year())
            }
            .width(min: 90, ideal: 110)

            TableColumn("Location", value: \.directory) { item in
                Text(verbatim: FinderActions.abbreviate(item.directory))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 260)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { paths in
            if !paths.isEmpty {
                Button("Show in Finder", systemImage: "folder") { FinderActions.reveal(Array(paths)) }
                Button("Copy Path", systemImage: "doc.on.clipboard") { FinderActions.copy(Array(paths)) }
            }
        } primaryAction: { paths in
            FinderActions.reveal(Array(paths))
        }
        .overlay {
            if items.isEmpty, !isSearching {
                ContentUnavailableView("No files match these filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private var footer: some View {
        HStack {
            let total = items.reduce(0) { $0 + $1.allocatedSize }
            Text("\(items.count.formatted()) files · \(total.formatted(.byteCount(style: .file)))")
                .monospacedDigit()
            if !selection.isEmpty {
                let selectedSize = items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.allocatedSize }
                Text("\(selection.count.formatted()) selected · \(selectedSize.formatted(.byteCount(style: .file)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder", systemImage: "folder") {
                FinderActions.reveal(Array(selection))
            }
            .disabled(selection.isEmpty)
        }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        let root = result.root
        let query = query
        let minimum = query.minimumSize.rawValue
        let cutoff = query.age.cutoff
        let found = await Task.detached(priority: .userInitiated) {
            root.files { file in
                file.allocatedSize >= minimum
                    && file.accessTime <= cutoff
                    && (query.kind == nil || file.kind == query.kind)
                    && (query.search.isEmpty || file.name.localizedCaseInsensitiveContains(query.search))
            }
        }.value
        guard !Task.isCancelled else { return }
        items = found.sorted(using: sortOrder)
        selection.formIntersection(Set(items.map(\.id)))
    }
}
