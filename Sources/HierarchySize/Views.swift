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
                        .background(Theme.paper)
                        StatusBar()
                    }
                } else {
                    ScanningView()
                }
            }
            .frame(minWidth: 640, minHeight: 420)
            .background(Theme.paper)
        }
        .tint(Theme.accent)
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
                Text("\(n.size(model.sizeMode).bytesString)\(n.isDirectory ? " in \(n.fileCount.formatted()) files" : "") will be moved to the Trash. The space is freed only after you empty the Trash.")
            }
        }
        .confirmationDialog(
            "Delete “\(model.pendingDeleteNow?.name ?? "")” immediately?",
            isPresented: Binding(get: { model.pendingDeleteNow != nil }, set: { if !$0 { model.pendingDeleteNow = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Immediately", role: .destructive) { model.confirmDeleteNow() }
            Button("Cancel", role: .cancel) { model.pendingDeleteNow = nil }
        } message: {
            if let n = model.pendingDeleteNow {
                Text("\(n.size(model.sizeMode).bytesString) will be deleted for good and freed right away. This can't be undone.")
            }
        }
        .confirmationDialog(
            "Administrator permission needed",
            isPresented: Binding(get: { model.pendingAdminDelete != nil }, set: { if !$0 { model.pendingAdminDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete as Administrator", role: .destructive) { model.confirmAdminDelete() }
            Button("Cancel", role: .cancel) { model.pendingAdminDelete = nil }
        } message: {
            Text("Some items in “\(model.pendingAdminDelete?.name ?? "")” belong to the system or another user. macOS will ask for your password to delete them.")
        }
        .alert("Run Hierarchy Size as Administrator?", isPresented: $model.showAdminPrompt) {
            Button("Run as Administrator") { model.runAsAdministrator() }
            Button("Continue as \(NSUserName())", role: .cancel) {}
            Button("Don't Ask Again") { UserDefaults.standard.set(true, forKey: AppModel.skipAdminPromptKey) }
        } message: {
            Text("As administrator (superuser) Hierarchy Size can read and delete files that belong to the system or other users, without asking for your password on every delete.\n\nYou can switch later from File › Run as Administrator.")
        }
        .sheet(isPresented: $model.showPermissions) {
            PermissionsView().environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshTrash()
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
        let home = AppModel.userHome
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
            Section("Cleanup") {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Trash")
                            Text(model.trashSize.map { $0 > 0 ? $0.bytesString : "Empty" } ?? "Needs permission to read")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: (model.trashSize ?? 1) > 0 ? "trash.fill" : "trash") }
                    Spacer()
                    if (model.trashSize ?? 1) > 0 {
                        Button("Empty") { model.emptyTrash() }.controlSize(.small)
                    }
                }
                Button { model.showPermissions = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Permissions")
                            Text(model.hasFullDiskAccess ? "Full Disk Access on" : "Full Disk Access off")
                                .font(.caption2).foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                        }
                    } icon: { Image(systemName: model.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield") }
                }
                .buttonStyle(.plain)
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
            EditorialBar(fraction: volume.fraction, warn: volume.fraction > 0.9)
                .frame(height: 3)
            Text("\(volume.available.bytesString) free of \(volume.total.bytesString)")
                .font(.system(size: 9.5, design: .monospaced)).textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Welcome & scanning

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Vol. 1 · Edition \(version)").kicker()
                    Spacer()
                    Text("A disk space analyzer for the Mac").kicker()
                }
                .padding(.bottom, 10)
                MastheadRule()

                VStack(alignment: .leading, spacing: 18) {
                    Text("Storage, explained").kicker(Theme.accent)
                    (Text("Where did all your ")
                     + Text("space").italic().foregroundColor(Theme.accent)
                     + Text(" go?"))
                        .font(Theme.display(64, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(-6)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Choose a drive or a folder. In a few seconds every folder is ranked from largest to smallest, with the share of space it takes.")
                        .font(Theme.display(19).italic())
                        .foregroundStyle(Theme.ink2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        Button { model.chooseFolder() } label: {
                            Text("Choose a folder  →")
                        }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        Text("or drag one onto this window").font(Theme.display(14).italic()).foregroundStyle(Theme.ink3)
                    }
                    .padding(.top, 6)
                }
                .padding(.vertical, 36)

                if !model.volumes.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("I.").font(Theme.display(30).italic()).foregroundStyle(Theme.accent)
                        Text("Your drives").font(Theme.display(30)).foregroundStyle(Theme.ink)
                    }
                    .padding(.bottom, 10)
                    Rectangle().fill(Theme.ink).frame(height: 1)
                    ForEach(Array(model.volumes.enumerated()), id: \.element.id) { i, v in
                        Button { model.scan(v.url) } label: {
                            HStack(alignment: .center, spacing: 18) {
                                Text(String(format: "%02d", i + 1)).kicker(Theme.accent).frame(width: 26, alignment: .leading)
                                Text(v.name).font(Theme.display(20)).foregroundStyle(Theme.ink)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text("\(v.available.bytesString) free of \(v.total.bytesString)").kicker()
                                    EditorialBar(fraction: v.fraction, warn: v.fraction > 0.9)
                                        .frame(width: 180, height: 5)
                                }
                            }
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Hairline()
                    }
                }
            }
            .padding(.horizontal, 48).padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Text("In progress").kicker(Theme.accent)
            Text("Reading your drive…").font(Theme.display(40).italic()).foregroundStyle(Theme.ink)
            ProgressView().controlSize(.small).tint(Theme.accent)
            HStack(spacing: 0) {
                stat("Files", model.live.files.formatted())
                Rectangle().fill(Theme.hair).frame(width: 1, height: 44)
                stat("Folders", model.live.folders.formatted())
                Rectangle().fill(Theme.hair).frame(width: 1, height: 44)
                stat("Size", model.live.bytes.bytesString)
            }
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ink).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 1) }
            Text(model.live.currentPath)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Cancel") { model.cancel() }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
    private func stat(_ t: String, _ v: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(Theme.display(26).monospacedDigit()).foregroundStyle(Theme.ink)
            Text(t).kicker()
        }
        .frame(width: 160)
    }
}

// MARK: - Header & status

struct SummaryHeader: View {
    @EnvironmentObject var model: AppModel
    let focus: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(focus.ancestors) { a in
                        Button(a.name) { model.setFocus(a) }
                            .buttonStyle(.plain)
                            .kicker(a === focus ? Theme.accent : Theme.ink3)
                        if a !== focus { Text("/").kicker(Theme.hair) }
                    }
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.name).font(Theme.display(15).italic()).foregroundStyle(Theme.ink2).lineLimit(1)
                    Text(focus.size(model.sizeMode).bytesString)
                        .font(Theme.display(40, weight: .regular).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                .padding(.trailing, 28)
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
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
        .background(Theme.paper)
        .overlay(alignment: .bottom) { MastheadRule() }
    }

    private func metric(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(v).font(Theme.display(19).monospacedDigit()).foregroundStyle(Theme.ink)
            Text(t).kicker()
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hair).frame(width: 1) }
    }
}

struct CategoryBar: View {
    let categories: [CategoryStat]
    var body: some View {
        let total = max(1, categories.reduce(Int64(0)) { $0 + $1.size })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(categories) { c in
                        Rectangle().fill(c.category.color)
                            .frame(width: max(0, g.size.width * CGFloat(Double(c.size) / Double(total)) - 1))
                            .help("\(c.category.rawValue): \(c.size.bytesString)")
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                ForEach(categories.prefix(7)) { c in
                    HStack(spacing: 5) {
                        Rectangle().fill(c.category.color).frame(width: 8, height: 8)
                        Text("\(c.category.rawValue) \(c.size.bytesString)").kicker()
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
                Text(s.path).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.ink2)
                Text(s.size(model.sizeMode).bytesString).foregroundStyle(Theme.ink).bold()
            } else {
                Text("Scanned in \(model.scanDuration.formatted(.number.precision(.fractionLength(1)))) s").foregroundStyle(Theme.ink3)
            }
            Spacer()
            if AppModel.isRoot {
                Text("● Administrator").foregroundStyle(Theme.accent).help("Running as superuser")
            }
            if model.scanErrors > 0 {
                Button {
                    model.showPermissions = true
                } label: {
                    Text("\(model.scanErrors) folders unreadable · grant access")
                        .underline()
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .textCase(.uppercase)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.paper)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ink).frame(height: 1) }
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
        Button("Delete Immediately…", role: .destructive) { model.requestDeleteNow(node) }
            .disabled(node.parent == nil)
    }
}

struct NameCell: View {
    let node: FileNode
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: node.isUnreadable ? "lock.fill" : node.category.symbol)
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Theme.ink2 : node.category.color)
                .frame(width: 16)
            Text(node.name)
                .font(node.isDirectory ? Theme.display(14, weight: .medium) : Theme.body)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Thin ink bar on a hairline track.
struct EditorialBar: View {
    let fraction: Double
    var warn = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hair)
                Rectangle().fill(warn ? Theme.accent : Theme.ink)
                    .frame(width: g.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
    }
}

struct PercentBar: View {
    let fraction: Double
    var body: some View {
        HStack(spacing: 8) {
            EditorialBar(fraction: fraction, warn: fraction >= 0.5).frame(height: 4)
            Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ink3)
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
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .alternatingRowBackgrounds(.disabled)
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
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .alternatingRowBackgrounds(.disabled)
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
                    Text("By category").font(Theme.display(24)).foregroundStyle(Theme.ink)
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
                .scrollContentBackground(.hidden)
                .background(Theme.paper)
                .alternatingRowBackgrounds(.disabled)
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
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .alternatingRowBackgrounds(.disabled)
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
                Text("Space by last modification date").font(Theme.display(26)).foregroundStyle(Theme.ink)
                Chart(stats.ages) { b in
                    BarMark(x: .value("Age", b.label), y: .value("Size", Double(b.size) / 1_000_000_000))
                        .foregroundStyle(Theme.accent)
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

// MARK: - Permissions

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Permissions").font(Theme.display(30)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            row(granted: model.hasFullDiskAccess,
                title: "Full Disk Access",
                detail: "Lets Hierarchy Size read and delete everywhere you can: the Trash, Mail, Safari, other apps' containers and protected caches. Without it some folders show as locked and some deletes fail with “Operation not permitted”.") {
                Button(model.hasFullDiskAccess ? "Open Settings" : "Grant Access…") { model.openPrivacySettings("Privacy_AllFiles") }
            }

            if !model.hasFullDiskAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to turn it on").font(.headline)
                    Text("1. Click **Grant Access…**. System Settings opens at Full Disk Access.")
                    Text("2. Switch on **Hierarchy Size**. If it isn't listed, press **+** and pick it from Applications.")
                    Text("3. Come back and click **Relaunch** so the change takes effect.")
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            row(granted: nil,
                title: "Control Finder (Empty Trash)",
                detail: "Used only when you click “Empty” on the Trash. macOS asks once the first time.") {
                Button("Open Settings") { model.openPrivacySettings("Privacy_Automation") }
            }

            row(granted: nil,
                title: "Administrator",
                detail: AppModel.isRoot
                    ? "Running as administrator (superuser). Files that belong to the system or other users can be deleted without extra prompts. Files protected by System Integrity Protection can never be deleted, by design."
                    : "Run as administrator to delete files that belong to the system or other users without a password prompt each time. Files protected by System Integrity Protection can never be deleted, by design.") {
                if AppModel.isRoot {
                    Text("Active").font(.callout.bold()).foregroundStyle(.orange)
                } else {
                    Button("Run as Administrator") { model.runAsAdministrator() }
                }
            }

            Spacer()
            HStack {
                Button { model.refreshTrash() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                Spacer()
                Button("Relaunch Hierarchy Size") { model.relaunch() }
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
        .onAppear { model.refreshTrash() }
    }

    private func row<B: View>(granted: Bool?, title: String, detail: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted == nil ? "info.circle" : granted! ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted == nil ? Color.secondary : granted! ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    if let g = granted {
                        Text(g ? "On" : "Off").font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background((g ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            button()
        }
    }
}
