import CleanerCore
import SwiftUI

/// Treemap of a folder's children. Folders also show their own children as
/// faint inner tiles, so the next level is visible before drilling in.
struct TreemapView: View {
    let items: [LensItem]
    @Binding var hovered: LensItem.ID?
    let open: (LensItem) -> Void

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let rects = Treemap.squarify(items.map { Double($0.size) }, in: bounds)

            Canvas { context, _ in
                for (item, rect) in zip(items, rects) {
                    draw(item, in: rect, context: &context)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hovered = index(at: location, rects: rects).map { items[$0].id }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture { location in
                if let index = index(at: location, rects: rects) {
                    open(items[index])
                }
            }
            .contextMenu {
                if let item = items.first(where: { $0.id == hovered }), let path = item.path {
                    LensItemMenu(item: item, path: path, open: open)
                }
            }
        }
    }

    private func index(at point: CGPoint, rects: [CGRect]) -> Int? {
        rects.firstIndex { $0.contains(point) }
    }

    private func draw(_ item: LensItem, in rect: CGRect, context: inout GraphicsContext) {
        let tile = rect.insetBy(dx: 1.5, dy: 1.5)
        guard tile.width > 1, tile.height > 1 else { return }
        let isHovered = item.id == hovered
        let shape = Path(roundedRect: tile, cornerRadius: min(8, tile.width / 4, tile.height / 4))
        context.fill(shape, with: .color(item.color.opacity(isHovered ? 0.95 : 0.72)))
        if isHovered {
            context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 2)
        }

        let showsLabel = tile.width > 56 && tile.height > 26
        if let directory = item.directory, tile.width > 90, tile.height > 70 {
            // Leave room at the top for the name and size labels.
            let labelHeight: CGFloat = tile.height > 44 ? 36 : 22
            let area = CGRect(
                x: tile.minX + 4, y: tile.minY + labelHeight,
                width: tile.width - 8, height: tile.height - labelHeight - 4
            )
            drawChildren(of: directory, in: area, context: &context)
        }
        guard showsLabel else { return }

        context.drawLayer { layer in
            layer.clip(to: shape)
            let title = item.name.isEmpty ? String(localized: "Other items") : item.name
            layer.draw(
                Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.white),
                at: CGPoint(x: tile.minX + 6, y: tile.minY + 4),
                anchor: .topLeading
            )
            if tile.height > 44 {
                layer.draw(
                    Text(verbatim: item.size.formatted(.byteCount(style: .file)))
                        .font(.caption2).foregroundStyle(.white.opacity(0.85)),
                    at: CGPoint(x: tile.minX + 6, y: tile.minY + 20),
                    anchor: .topLeading
                )
            }
        }
    }

    private func drawChildren(of directory: DirectoryNode, in area: CGRect, context: inout GraphicsContext) {
        guard area.width > 20, area.height > 20 else { return }
        let children = LensItem.items(in: directory, limit: 24)
        let rects = Treemap.squarify(children.map { Double($0.size) }, in: area)
        for rect in rects {
            let inner = rect.insetBy(dx: 1, dy: 1)
            guard inner.width > 2, inner.height > 2 else { continue }
            context.fill(
                Path(roundedRect: inner, cornerRadius: min(4, inner.width / 4, inner.height / 4)),
                with: .color(.white.opacity(0.14))
            )
        }
    }
}

/// Context menu actions for a Space Lens item.
struct LensItemMenu: View {
    let item: LensItem
    let path: String
    let open: (LensItem) -> Void

    var body: some View {
        if item.directory != nil {
            Button("Open", systemImage: "arrow.down.right.circle") { open(item) }
        }
        Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([path]) }
        Button("Copy Path", systemImage: "doc.on.clipboard") { FinderActions.copy([path]) }
    }
}
