import Charts
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Group {
                if model.root == nil && !model.isScanning {
                    WelcomeView()
                } else if let focus = model.focus, !model.isScanning {
                    VStack(spacing: 0) {
                        SummaryHeader(focus: focus)
                        Divider()
                        Group {
                            if !model.searchText.isEmpty {
                                SearchResultsView()
                            } else {
                                switch model.tab {
                                case .tree: TreeTableView(focus: focus)
                                case .treemap: TreemapView()
                                case .types: FileTypesView()
                                case .largest: LargestFilesView()
                                case .age: FileAgeView()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        StatusBar()
                    }
                } else {
                    ScanningView()
                }
            }
            .frame(minWidth: 640, minHeight: 420)
        }
        .toolbar { MainToolbar() }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search files & folders")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    Task { @MainActor in model.scan(url) }
                }
            }
            return true
        }
        .confirmationDialog(
            "Move “\(model.pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: {
            if let n = model.pendingTrash {
                Text("\(n.size(model.sizeMode).bytesString)\(n.isDirectory ? " in \(n.fileCount.formatted()) files" : "") will be moved to the Trash. You can restore it from the Trash.")
            }
        }
        .sheet(isPresented: $model.showHiddenSpace) {
            HiddenSpaceView().environmentObject(model)
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goUp() } label: { Label("Up", systemImage: "chevron.up") }
                .disabled(model.focus?.parent == nil)
                .help("Go to parent folder (⌘↑)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.chooseFolder() } label: { Label("Scan Folder", systemImage: "folder.badge.plus") }
                .help("Choose a folder to scan (⌘O)")
            Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.focus == nil || model.isScanning)
                .help("Rescan the current folder (⌘R)")
            Picker("View", selection: $model.tab) {
                ForEach(MainTab.allCases) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented)
            .help("Switch view")
            Picker("Size", selection: $model.sizeMode) {
                ForEach(SizeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .help("Show allocated size on disk or logical file size")
            Button { model.exportCSV() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.focus == nil)
                .help("Export the current folder as CSV (⌘E)")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    private var places: [(String, String, URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            ("Home", "house", home),
            ("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
            ("Documents", "doc", home.appendingPathComponent("Documents")),
            ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications")),
            ("Library", "building.columns", home.appendingPathComponent("Library")),
        ]
    }

    var body: some View {
        List {
            Section("Drives") {
                ForEach(model.volumes) { v in
                    Button { model.scan(v.url) } label: { VolumeRow(volume: v) }
                        .buttonStyle(.plain)
                }
                Button { model.showHiddenSpace = true } label: { Label("Hidden Space…", systemImage: "eye.slash") }
                    .buttonStyle(.plain)
                    .help("Snapshots, system volumes, swap and disk images")
            }
            Section("Places") {
                ForEach(places, id: \.0) { p in
                    Button { model.scan(p.2) } label: { Label(p.0, systemImage: p.1) }
                        .buttonStyle(.plain)
                }
            }
            if let root = model.root {
                Section("Current Scan") {
                    Button { model.setFocus(root) } label: {
                        Label(root.name, systemImage: "scope")
                    }.buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct VolumeRow: View {
    let volume: VolumeInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(volume.name, systemImage: volume.url.path == "/" ? "internaldrive" : "externaldrive")
            ProgressView(value: volume.fraction)
                .tint(volume.fraction > 0.9 ? .red : volume.fraction > 0.75 ? .orange : .accentColor)
            Text("\(volume.available.bytesString) free of \(volume.total.bytesString)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Welcome & scanning

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Hierarchy Size").font(.largeTitle.bold())
                Text("See what's taking up space on your Mac.").foregroundStyle(.secondary)
            }
            Button { model.chooseFolder() } label: {
                Label("Choose a Folder to Scan", systemImage: "folder.badge.plus").padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            if !model.volumes.isEmpty {
                HStack(spacing: 14) {
                    ForEach(model.volumes) { v in
                        Button { model.scan(v.url) } label: {
                            VolumeRow(volume: v).frame(width: 190).padding(12)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Or drag a folder onto this window.").font(.callout).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning…").font(.title2.bold())
            HStack(spacing: 28) {
                stat("Files", model.live.files.formatted())
                stat("Folders", model.live.folders.formatted())
                stat("Size", model.live.bytes.bytesString)
            }
            Text(model.live.currentPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func stat(_ t: String, _ v: String) -> some View {
        VStack { Text(v).font(.title3.monospacedDigit().bold()); Text(t).font(.caption).foregroundStyle(.secondary) }
    }
}

// MARK: - Header & status

struct SummaryHeader: View {
    @EnvironmentObject var model: AppModel
    let focus: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(focus.ancestors) { a in
                        Button(a.name) { model.setFocus(a) }
                            .buttonStyle(.plain)
                            .foregroundStyle(a === focus ? .primary : .secondary)
                            .fontWeight(a === focus ? .semibold : .regular)
                        if a !== focus { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text(focus.size(model.sizeMode).bytesString).font(.system(size: 26, weight: .bold).monospacedDigit())
                metric("Files", focus.fileCount.formatted())
                metric("Folders", focus.folderCount.formatted())
                if let v = model.volume(containing: focus), v.total > 0 {
                    metric("Of drive", (Double(focus.allocatedSize) / Double(v.total)).formatted(.percent.precision(.fractionLength(1))))
                }
                if let m = focus.modified { metric("Last change", m.formatted(date: .abbreviated, time: .omitted)) }
                Spacer()
            }
            if let stats = model.stats, !stats.categories.isEmpty {
                CategoryBar(categories: stats.categories)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func metric(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.headline.monospacedDigit())
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CategoryBar: View {
    let categories: [CategoryStat]
    var body: some View {
        let total = max(1, categories.reduce(Int64(0)) { $0 + $1.size })
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(categories) { c in
                        Rectangle().fill(c.category.color)
                            .frame(width: max(0, g.size.width * CGFloat(Double(c.size) / Double(total)) - 1))
                            .help("\(c.category.rawValue): \(c.size.bytesString)")
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(categories.prefix(7)) { c in
                    HStack(spacing: 4) {
                        Circle().fill(c.category.color).frame(width: 7, height: 7)
                        Text("\(c.category.rawValue) \(c.size.bytesString)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            if let s = model.selection {
                Image(systemName: s.category.symbol)
                Text(s.path).lineLimit(1).truncationMode(.middle)
                Text(s.size(model.sizeMode).bytesString).bold()
            } else {
                Text("Scanned in \(model.scanDuration.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Spacer()
            if model.scanErrors > 0 {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    Label("\(model.scanErrors) folders couldn't be read — grant Full Disk Access", systemImage: "lock.trianglebadge.exclamationmark")
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Shared row bits

struct NodeMenu: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    var body: some View {
        if node.isDirectory {
            Button("Show Contents") { model.setFocus(node) }
            Button("Rescan This Folder") { model.scan(node.url) }
            Divider()
        }
        Button("Open") { NSWorkspace.shared.open(node.url) }
        Button("Reveal in Finder") { model.reveal(node) }
        Button("Copy Path") { model.copyPath(node) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.requestTrash(node) }
            .disabled(node.parent == nil)
    }
}

struct NameCell: View {
    let node: FileNode
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isUnreadable ? "lock.fill" : node.category.symbol)
                .foregroundStyle(node.isDirectory ? Color.accentColor : node.category.color)
                .frame(width: 16)
            Text(node.name).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct PercentBar: View {
    let fraction: Double
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(min(1, max(0, fraction))))
                }
            }
            .frame(height: 9)
            Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Tree

struct TreeTableView: View {
    @EnvironmentObject var model: AppModel
    let focus: FileNode
    @State private var sortOrder: [KeyPathComparator<FileNode>] = [KeyPathComparator(\FileNode.allocatedSize, order: .reverse)]

    var body: some View {
        let mode = model.sizeMode
        let _ = model.revision
        Table(focus.children, children: \.outlineChildren, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \FileNode.name) { NameCell(node: $0) }
                .width(min: 180, ideal: 320)
            TableColumn("% of Parent") { (n: FileNode) in PercentBar(fraction: n.fractionOfParent(mode)) }
                .width(min: 110, ideal: 150)
            TableColumn("Size", value: \FileNode.allocatedSize) { (n: FileNode) in
                Text(n.size(mode).bytesString).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Files", value: \FileNode.fileCount) { (n: FileNode) in
                Text(n.isDirectory ? n.fileCount.formatted() : "").monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Folders") { (n: FileNode) in
                Text(n.isDirectory ? n.folderCount.formatted() : "").monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 65)
            TableColumn("Modified", value: \FileNode.modifiedSortValue) { (n: FileNode) in
                Text(n.modified?.formatted(date: .abbreviated, time: .shortened) ?? "").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Type") { (n: FileNode) in
                Text(n.isDirectory ? "Folder" : (n.fileExtension.isEmpty ? n.category.rawValue : n.fileExtension.uppercased()))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: FileNode.self) { items in
            if let n = items.first { NodeMenu(node: n) }
        } primaryAction: { items in
            if let n = items.first { model.open(n) }
        }
        .onChange(of: sortOrder) { _, new in
            guard let c = new.first else { return }
            let key: SortKey
            switch c.keyPath {
            case \FileNode.name: key = .name
            case \FileNode.fileCount: key = .files
            case \FileNode.modifiedSortValue: key = .modified
            default: key = .size
            }
            // Name ascending = A→Z; for numbers "forward" means largest first.
            let ascending = key == .name ? c.order == .reverse : c.order == .forward
            model.setSort(key, ascending: ascending)
        }
    }
}

extension FileNode {
    var modifiedSortValue: Date { modified ?? .distantPast }
}

// MARK: - Search

struct SearchResultsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let mode = model.sizeMode
        VStack(spacing: 0) {
            HStack {
                Text("\(model.searchResults.count.formatted()) matches for “\(model.searchText)”")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 6)
            Table(model.searchResults, selection: $model.selection) {
                TableColumn("Name") { NameCell(node: $0) }.width(min: 160, ideal: 260)
                TableColumn("Size") { (n: FileNode) in Text(n.size(mode).bytesString).monospacedDigit() }.width(80)
                TableColumn("Location") { (n: FileNode) in
                    Text(n.url.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                TableColumn("Modified") { (n: FileNode) in
                    Text(n.modified?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary)
                }.width(100)
            }
            .contextMenu(forSelectionType: FileNode.self) { items in
                if let n = items.first { NodeMenu(node: n) }
            } primaryAction: { items in
                if let n = items.first { model.searchText = ""; model.open(n) }
            }
        }
    }
}

// MARK: - File types

struct FileTypesView: View {
    @EnvironmentObject var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\ExtensionStat.size, order: .reverse)]

    var body: some View {
        if let stats = model.stats {
            let total = max(1, stats.extensions.reduce(Int64(0)) { $0 + $1.size })
            let rows = stats.extensions.sorted(using: sortOrder)
            HSplitView {
                VStack(alignment: .leading) {
                    Text("By Category").font(.headline)
                    Chart(stats.categories) { c in
                        SectorMark(angle: .value("Size", Double(c.size)), innerRadius: .ratio(0.55), angularInset: 1)
                            .foregroundStyle(c.category.color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .frame(minHeight: 200)
                    ForEach(stats.categories) { c in
                        HStack {
                            Circle().fill(c.category.color).frame(width: 9, height: 9)
                            Text(c.category.rawValue)
                            Spacer()
                            Text(c.size.bytesString).monospacedDigit()
                            Text((Double(c.size) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                                .foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }.font(.callout)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Extension", value: \ExtensionStat.ext) { s in
                        HStack { Circle().fill(s.category.color).frame(width: 8, height: 8); Text(s.label) }
                    }
                    TableColumn("Category") { (s: ExtensionStat) in Text(s.category.rawValue).foregroundStyle(.secondary) }
                    TableColumn("Size", value: \ExtensionStat.size) { s in Text(s.size.bytesString).monospacedDigit() }
                    TableColumn("% of Total") { (s: ExtensionStat) in PercentBar(fraction: Double(s.size) / Double(total)) }
                        .width(min: 120, ideal: 160)
                    TableColumn("Files", value: \ExtensionStat.count) { s in Text(s.count.formatted()).monospacedDigit() }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Largest files

struct LargestFilesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let mode = model.sizeMode
        let _ = model.revision
        if let stats = model.stats {
            Table(stats.topFiles.filter { $0.parent != nil }, selection: $model.selection) {
                TableColumn("#") { (n: FileNode) in
                    Text("\((stats.topFiles.firstIndex(of: n) ?? 0) + 1)").foregroundStyle(.secondary).monospacedDigit()
                }.width(36)
                TableColumn("Name") { NameCell(node: $0) }.width(min: 160, ideal: 260)
                TableColumn("Size") { (n: FileNode) in Text(n.size(mode).bytesString).monospacedDigit().bold() }.width(80)
                TableColumn("Folder") { (n: FileNode) in
                    Text(n.url.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                TableColumn("Modified") { (n: FileNode) in
                    Text(n.modified?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary)
                }.width(100)
            }
            .contextMenu(forSelectionType: FileNode.self) { items in
                if let n = items.first { NodeMenu(node: n) }
            } primaryAction: { items in
                if let n = items.first { model.reveal(n) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - File age

struct FileAgeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let stats = model.stats {
            let total = max(1, stats.ages.reduce(Int64(0)) { $0 + $1.size })
            VStack(alignment: .leading, spacing: 16) {
                Text("Space by last modification date").font(.headline)
                Chart(stats.ages) { b in
                    BarMark(x: .value("Age", b.label), y: .value("Size", Double(b.size) / 1_000_000_000))
                        .foregroundStyle(Color.accentColor.gradient)
                        .annotation(position: .top) {
                            Text(b.size.bytesString).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYAxisLabel("GB")
                .frame(minHeight: 220)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("Age").bold(); Text("Size").bold(); Text("Share").bold(); Text("Files").bold()
                    }
                    ForEach(stats.ages) { b in
                        GridRow {
                            Text(b.label)
                            Text(b.size.bytesString).monospacedDigit()
                            Text((Double(b.size) / Double(total)).formatted(.percent.precision(.fractionLength(1)))).monospacedDigit()
                            Text(b.count.formatted()).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                Spacer()
            }
            .padding(20)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
