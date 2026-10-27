import CleanerCore
import SwiftUI

/// One pass over the whole Mac, and a plain answer to "so what now".
///
/// The ring is for someone who knows which tool they want. This is for everyone else:
/// press once, wait, read what it found and what is worth doing about it.
struct SmartScanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            switch state.smartScan.phase {
            case .idle:
                invitation
            case .scanning:
                BusyView(title: "Looking over the whole Mac…")
            case .cleaning:
                BusyView(title: "Cleaning…")
            case .ready:
                findings
            case let .cleaned(result):
                CleanupResultView(result: result) {
                    Task { await state.smartScan.run(state) }
                } done: {
                    state.open(.hub)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Check Everything")
    }

    private var invitation: some View {
        ContentUnavailableView {
            Label("Check Everything", systemImage: "wand.and.sparkles")
        } description: {
            Text("Junk, what removed apps left behind, the Trash on every disk, and the security of what is installed — in one pass. Nothing is removed without being shown first.")
        } actions: {
            Button("Start") { Task { await state.smartScan.run(state) } }
                .prominentButton()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private var findings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What the scan found")
                    .font(.title2.weight(.semibold))
                    .appears()

                found(
                    title: "Junk and caches", module: .systemJunk,
                    size: state.systemJunk.totalSize + state.developerJunk.totalSize, delay: 0.04
                )
                found(
                    title: "Left behind by removed apps", module: .leftovers,
                    size: state.leftovers.totalSize, delay: 0.08
                )
                found(title: "In the Trash", module: .trash, size: state.trash.totalSize, delay: 0.12)

                if state.security.score < 100 {
                    suggestion(
                        title: "Security is worth a look",
                        detail: "The analyser scored this Mac \(state.security.score) out of 100.",
                        module: .securityAnalyzer, symbol: "checkmark.shield", delay: 0.16
                    )
                }

                Text("Where to go next")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 10)
                    .appears(0.2)

                suggestion(
                    title: "Remove an app properly",
                    detail: "With everything it left in the libraries, and through Homebrew when that is what installed it.",
                    module: .uninstaller, symbol: "trash.square", delay: 0.24
                )
                suggestion(
                    title: "Find the big files",
                    detail: "Search by size, age or contents, anywhere on the disk.",
                    module: .deepSearch, symbol: "magnifyingglass", delay: 0.28
                )
                suggestion(
                    title: "Everything else",
                    detail: "The hub holds every tool, grouped by what you came to do.",
                    module: .hub, symbol: "circle.hexagongrid", delay: 0.32
                )
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func found(title: LocalizedStringKey, module: Module, size: Int64, delay: Double) -> some View {
        Button {
            state.open(module)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: module.symbol)
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                Text(title)
                Spacer()
                Text(verbatim: size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(size > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassCard()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .appears(delay)
    }

    private func suggestion(
        title: LocalizedStringKey, detail: LocalizedStringKey, module: Module,
        symbol: String, delay: Double
    ) -> some View {
        Button {
            state.open(module)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassCard()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .appears(delay)
    }
}
