import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VolumeInfo: Identifiable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    var id: URL { url }
    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MainTab: String, CaseIterable, Identifiable {
    case tree = "Tree"
    case treemap = "Treemap"
    case types = "File Types"
    case largest = "Largest Files"
    case age = "File Age"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .tree: "list.bullet.indent"
        case .treemap: "square.grid.3x3.square"
        case .types: "chart.pie"
        case .largest: "arrow.up.doc"
        case .age: "calendar"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var root: FileNode?
    @Published var focus: FileNode?
    @Published var selection: FileNode?
    @Published var tab: MainTab = .tree
    @Published var isScanning = false
    @Published var live = ScanProgress.Snapshot()
    @Published var stats: ScanStats?
    @Published var revision = 0
    @Published var volumes: [VolumeInfo] = []
    @Published var scanDuration: TimeInterval = 0
    @Published var scanErrors = 0
    @Published var pendingTrash: FileNode?
    @Published var errorMessage: String?
    @Published var searchText = "" { didSet { runSearch() } }
    @Published var searchResults: [FileNode] = []
    @Published var sizeMode: SizeMode = .allocated {
        didSet { applySort(); recomputeStats() }
    }
    @Published var sortKey: SortKey = .size
    @Published var sortAscending = false

    private var progress: ScanProgress?
    private var timer: Timer?
    private var scanStart = Date()
    private var searchTask: Task<Void, Never>?

    init() {
        refreshVolumes()
        // `open -a "Hierarchy Size" --args /some/folder` scans that folder on launch.
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                let url = URL(fileURLWithPath: arg)
                DispatchQueue.main.async { self.scan(url) }
            }
        }
    }

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or drive to analyze"
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    func scan(_ url: URL) {
        cancel()
        let p = ScanProgress()
        progress = p
        isScanning = true
        live = .init()
        searchText = ""
        scanStart = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.progress else { return }
                self.live = p.snapshot
            }
        }
        let mode = sizeMode
        Task.detached(priority: .userInitiated) {
            let scanner = Scanner(root: url, progress: p)
            let tree = scanner.scan(root: url)
            tree.sortRecursively(by: .size, mode: mode, ascending: false)
            let st = ScanStats.compute(root: tree, mode: mode)
            await MainActor.run {
                guard self.progress === p else { return }
                self.timer?.invalidate()
                self.isScanning = false
                if p.isCancelled { return }
                self.sortKey = .size
                self.sortAscending = false
                self.root = tree
                self.focus = tree
                self.selection = nil
                self.stats = st
                self.scanErrors = p.snapshot.errors
                self.scanDuration = Date().timeIntervalSince(self.scanStart)
                self.revision += 1
                self.refreshVolumes()
            }
        }
    }

    func cancel() {
        progress?.cancel()
        timer?.invalidate()
        isScanning = false
    }

    func rescan() {
        if let url = (focus ?? root)?.url { scan(url) }
    }

    // MARK: Navigation

    func setFocus(_ node: FileNode) {
        guard node.isDirectory else { return }
        focus = node
        selection = nil
        recomputeStats()
    }

    func goUp() {
        if let p = focus?.parent { setFocus(p) }
    }

    func open(_ node: FileNode) {
        if node.isDirectory { setFocus(node) } else { NSWorkspace.shared.open(node.url) }
    }

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Sorting

    func setSort(_ key: SortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        applySort()
    }

    private func applySort() {
        root?.sortRecursively(by: sortKey, mode: sizeMode, ascending: sortAscending)
        revision += 1
    }

    // MARK: Stats & search

    func recomputeStats() {
        guard let f = focus else { stats = nil; return }
        let mode = sizeMode
        let rev = revision
        Task.detached(priority: .userInitiated) {
            let st = ScanStats.compute(root: f, mode: mode)
            await MainActor.run {
                if self.focus === f && self.revision == rev { self.stats = st }
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let f = focus else { searchResults = []; return }
        let mode = sizeMode
        searchTask = Task.detached(priority: .userInitiated) {
            var out: [FileNode] = []
            var stack: [FileNode] = [f]
            while let n = stack.popLast() {
                if Task.isCancelled { return }
                if n !== f, n.name.localizedCaseInsensitiveContains(q) { out.append(n) }
                if n.isDirectory { stack.append(contentsOf: n.children) }
            }
            out.sort { $0.size(mode) > $1.size(mode) }
            if out.count > 2000 { out.removeLast(out.count - 2000) }
            let results = out
            await MainActor.run { if !Task.isCancelled { self.searchResults = results } }
        }
    }

    // MARK: Deleting

    func requestTrash(_ node: FileNode) {
        guard node.parent != nil else { return }
        pendingTrash = node
    }

    func confirmTrash() {
        guard let node = pendingTrash else { return }
        pendingTrash = nil
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if let f = focus, f.isDescendant(of: node) { focus = node.parent }
            if let s = selection, s.isDescendant(of: node) { selection = nil }
            node.detachFromParent()
            searchResults.removeAll { $0.isDescendant(of: node) }
            revision += 1
            recomputeStats()
            refreshVolumes()
        } catch {
            errorMessage = "Couldn't move “\(node.name)” to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: Volumes

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            let avail = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(url: u, name: v.volumeLocalizedName ?? u.lastPathComponent, total: total, available: avail)
        }
    }

    func volume(containing node: FileNode) -> VolumeInfo? {
        let p = node.path
        return volumes.filter { p.hasPrefix($0.url.path) }.max { $0.url.path.count < $1.url.path.count }
    }

    // MARK: Export

    func exportCSV() {
        guard let f = focus else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(f.name) – HierarchySize.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let iso = ISO8601DateFormatter()
            func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var out = "Path,Type,Size on Disk (bytes),File Size (bytes),Files,Folders,Modified\n"
            var stack: [FileNode] = [f]
            while let n = stack.popLast() {
                out += [esc(n.path), n.isDirectory ? "Folder" : "File", String(n.allocatedSize), String(n.logicalSize),
                        String(n.isDirectory ? n.fileCount : 1), String(n.folderCount),
                        n.modified.map { iso.string(from: $0) } ?? ""].joined(separator: ",") + "\n"
                stack.append(contentsOf: n.children.reversed())
            }
            do { try out.write(to: url, atomically: true, encoding: .utf8) } catch {
                await MainActor.run { self.errorMessage = "Export failed: \(error.localizedDescription)" }
            }
        }
    }
}
