import SwiftUI

extension FileCategory {
    /// Muted, print-like palette.
    var color: Color {
        switch self {
        case .folder: Color(red: 0.55, green: 0.52, blue: 0.47)
        case .image: Color(red: 0.80, green: 0.47, blue: 0.24)
        case .video: Color(red: 0.66, green: 0.23, blue: 0.20)
        case .audio: Color(red: 0.47, green: 0.33, blue: 0.53)
        case .document: Color(red: 0.20, green: 0.33, blue: 0.53)
        case .code: Color(red: 0.31, green: 0.48, blue: 0.40)
        case .archive: Color(red: 0.76, green: 0.62, blue: 0.27)
        case .app: Color(red: 0.27, green: 0.38, blue: 0.62)
        case .data: Color(red: 0.36, green: 0.55, blue: 0.60)
        case .other: Color(red: 0.62, green: 0.59, blue: 0.53)
        }
    }
}

struct TreemapCell {
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let isLeaf: Bool
}

enum Treemap {
    /// Squarified treemap layout (Bruls, Huizing, van Wijk).
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var r = rect
        var i = 0

        func worst(_ sum: Double, _ mx: Double, _ mn: Double, _ side: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * mx / s2, s2 / (w2 * mn))
        }

        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var sum = areas[i], mx = areas[i], mn = areas[i]
            var current = worst(sum, mx, mn, side)
            var j = i + 1
            while j < areas.count {
                let a = areas[j]
                let w = worst(sum + a, max(mx, a), min(mn, a), side)
                if w > current { break }
                sum += a; mx = max(mx, a); mn = min(mn, a); current = w; j += 1
            }
            if r.width >= r.height {
                let colW = CGFloat(sum) / r.height
                var y = r.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / colW
                    result.append(CGRect(x: r.minX, y: y, width: colW, height: h)); y += h
                }
                r = CGRect(x: r.minX + colW, y: r.minY, width: max(0, r.width - colW), height: r.height)
            } else {
                let rowH = CGFloat(sum) / r.width
                var x = r.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / rowH
                    result.append(CGRect(x: x, y: r.minY, width: w, height: rowH)); x += w
                }
                r = CGRect(x: r.minX, y: r.minY + rowH, width: r.width, height: max(0, r.height - rowH))
            }
            i = j
        }
        return result
    }

    static let headerHeight: CGFloat = 16

    static func layout(_ root: FileNode, in rect: CGRect, mode: SizeMode, maxCells: Int = 25_000) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        func build(_ node: FileNode, _ rect: CGRect, _ depth: Int) {
            let kids = node.isDirectory ? node.children.filter { $0.size(mode) > 0 }.sorted { $0.size(mode) > $1.size(mode) } : []
            let canRecurse = !kids.isEmpty && rect.width > 6 && rect.height > 6 && cells.count < maxCells && depth < 12
            cells.append(TreemapCell(node: node, rect: rect, depth: depth, isLeaf: !canRecurse))
            guard canRecurse else { return }
            var inner = depth == 0 ? rect : rect.insetBy(dx: 1.5, dy: 1.5)
            if depth > 0 && rect.height > 44 && rect.width > 60 {
                inner.origin.y += headerHeight - 1.5
                inner.size.height -= headerHeight - 1.5
            }
            guard inner.width > 1, inner.height > 1 else { return }
            let rects = squarify(kids.map { Double($0.size(mode)) }, in: inner)
            for (k, r) in zip(kids, rects) where r.width >= 1.5 && r.height >= 1.5 {
                build(k, r, depth + 1)
            }
        }
        build(root, rect, 0)
        return cells
    }
}

/// Holds the last layout so hovering does not recompute it.
final class TreemapCache {
    var key: String = ""
    var cells: [TreemapCell] = []
}

struct TreemapView: View {
    @EnvironmentObject var model: AppModel
    @State private var cache = TreemapCache()
    @State private var hovered: FileNode?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        if let focus = model.focus {
            GeometryReader { geo in
                let cells = cellsFor(focus, size: geo.size)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(cells, in: &ctx) }
                    if let h = hovered {
                        tooltip(h)
                            .position(tooltipPosition(in: geo.size))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverPoint = p
                        hovered = hit(cells, p)
                    case .ended:
                        hovered = nil
                    }
                }
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { v in
                        if let n = hit(cells, v.location) {
                            model.setFocus(n.isDirectory ? n : (n.parent ?? n))
                        }
                    }.exclusively(before: SpatialTapGesture().onEnded { v in
                        model.selection = hit(cells, v.location)
                    })
                )
                .contextMenu {
                    if let n = hovered ?? model.selection { NodeMenu(node: n) }
                }
            }
            .padding(8)
            .background(Theme.paper)
            .overlay(alignment: .bottomLeading) {
                Text("Click to select · Double-click a folder to zoom in · ⌘↑ to go up")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(6).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
            }
        }
    }

    private func cellsFor(_ focus: FileNode, size: CGSize) -> [TreemapCell] {
        let key = "\(ObjectIdentifier(focus).hashValue)-\(Int(size.width))x\(Int(size.height))-\(model.sizeMode.rawValue)-\(model.revision)"
        if cache.key != key {
            cache.cells = Treemap.layout(focus, in: CGRect(origin: .zero, size: size), mode: model.sizeMode)
            cache.key = key
        }
        return cache.cells
    }

    private func hit(_ cells: [TreemapCell], _ p: CGPoint) -> FileNode? {
        for c in cells.reversed() where c.depth > 0 && c.rect.contains(p) { return c.node }
        return nil
    }

    private func draw(_ cells: [TreemapCell], in ctx: inout GraphicsContext) {
        let selected = model.selection
        for c in cells where c.depth > 0 {
            let r = c.rect
            let path = Path(r.insetBy(dx: 0.5, dy: 0.5))
            if c.isLeaf {
                let base = c.node.category.color
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [base.opacity(0.95), base.opacity(0.65)]),
                    startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
                ctx.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
                if r.width > 50 && r.height > 18 {
                    let label = Text(c.node.name).font(.system(size: 10, weight: .medium)).foregroundColor(.white)
                    ctx.draw(label, in: r.insetBy(dx: 4, dy: 3))
                    if r.height > 32 {
                        let sz = Text(c.node.size(model.sizeMode).bytesString).font(.system(size: 9)).foregroundColor(.white.opacity(0.85))
                        ctx.draw(sz, in: CGRect(x: r.minX + 4, y: r.minY + 15, width: r.width - 8, height: 12))
                    }
                }
            } else {
                let shade = max(0.08, 0.22 - Double(c.depth) * 0.03)
                ctx.fill(path, with: .color(Color.primary.opacity(shade)))
                ctx.stroke(path, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
                if r.height > 44 && r.width > 60 {
                    let t = Text("\(c.node.name)  \(c.node.size(model.sizeMode).bytesString)")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.primary)
                    ctx.draw(t, in: CGRect(x: r.minX + 4, y: r.minY + 2, width: r.width - 8, height: 13))
                }
            }
        }
        for c in cells where c.node === selected || c.node === hovered {
            let color: Color = c.node === selected ? .accentColor : .white
            ctx.stroke(Path(c.rect.insetBy(dx: 1, dy: 1)), with: .color(color), lineWidth: c.node === selected ? 3 : 2)
        }
    }

    private func tooltipPosition(in size: CGSize) -> CGPoint {
        let w: CGFloat = 260, h: CGFloat = 70
        var x = hoverPoint.x + w / 2 + 14
        var y = hoverPoint.y + h / 2 + 14
        if x + w / 2 > size.width { x = hoverPoint.x - w / 2 - 14 }
        if y + h / 2 > size.height { y = hoverPoint.y - h / 2 - 14 }
        return CGPoint(x: x, y: y)
    }

    private func tooltip(_ n: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(n.name, systemImage: n.category.symbol).font(.callout.bold()).lineLimit(1)
            Text(n.size(model.sizeMode).bytesString + (n.isDirectory ? " · \(n.fileCount.formatted()) files" : ""))
                .font(.caption)
            Text(n.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .padding(8)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }
}
