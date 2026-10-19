import CleanerCore
import SwiftUI

/// Explains the storage figure macOS calls "System Data", which is mostly app data.
struct SystemDataCard: View {
    @State private var items: [SystemDataItem] = []
    @State private var scanning = false
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What System Data is made of").font(.headline)
                Spacer()
                if scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(items.isEmpty ? "Look" : "Look Again") { Task { await look() } }
                }
            }
            if items.isEmpty, !scanning {
                Text("System Settings counts what your apps keep in your Library as system data, which is why the figure looks unexplainable. This shows which apps it really is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.name)
                        Text(verbatim: item.place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: item.size.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                    Button("Show in Finder") { FinderActions.reveal([item.path]) }
                        .buttonStyle(.link)
                }
            }
            if !items.isEmpty {
                Text("Removing any of this is the app's own business: delete games from its launcher, images from Docker, and so on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }

    private func look() async {
        scanning = true
        defer { scanning = false }
        items = await SystemDataBreakdown.scan()
    }
}
