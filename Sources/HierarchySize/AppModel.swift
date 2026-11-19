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
    @Published var showHiddenSpace = false
    @Published var hiddenReport: HiddenSpaceReport?
    @Published var hiddenLoading = false
    @Published var pendingDeleteNow: FileNode?
    @Published var pendingAdminDelete: FileNode?
    @Published var trashSize: Int64?
    @Published var trashCount = 0
    @Published var hasFullDiskAccess = false
    @Published var showPermissions = false
    @Published var showAdminPrompt = false
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
        refreshTrash()
        if !Self.isRoot && !UserDefaults.standard.bool(forKey: Self.skipAdminPromptKey) {
            showAdminPrompt = true
        }
        // `open -a "Hierarchy Size" --args /some/folder` scans that folder on launch.
        // `--tab=treemap` (tree, treemap, types, largest, age) opens that view.
        let args = Array(CommandLine.arguments.dropFirst())
        if let t = args.first(where: { $0.hasPrefix("--tab=") })?.dropFirst(6) {
            let map: [String: MainTab] = ["tree": .tree, "treemap": .treemap, "types": .types, "largest": .largest, "age": .age]
            if let tab = map[String(t)] { self.tab = tab }
        }
        if let dir = args.first(where: { a in
            var isDir: ObjCBool = false
            return !a.hasPrefix("-") && FileManager.default.fileExists(atPath: a, isDirectory: &isDir) && isDir.boolValue
        }) {
            let url = URL(fileURLWithPath: dir)
            DispatchQueue.main.async { self.scan(url) }
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
            if Self.isRoot {
                try Self.moveToUserTrash(node.url)
            } else {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            }
            removeFromTree(node)
        } catch {
            errorMessage = "Couldn't move “\(node.name)” to the Trash: \(error.localizedDescription)"
        }
    }

    func requestDeleteNow(_ node: FileNode) {
        guard node.parent != nil, Self.isSafeToDelete(node.url) else {
            errorMessage = "“\(node.name)” is a protected system location and can't be deleted from here."
            return
        }
        pendingDeleteNow = node
    }

    /// Deletes permanently (skips the Trash). Falls back to an administrator prompt when needed.
    func confirmDeleteNow() {
        guard let node = pendingDeleteNow else { return }
        pendingDeleteNow = nil
        do {
            try FileManager.default.removeItem(at: node.url)
            removeFromTree(node)
        } catch {
            if FileManager.default.fileExists(atPath: node.path) {
                pendingAdminDelete = node
            } else {
                removeFromTree(node)   // partly removed but gone now
            }
        }
    }

    func confirmAdminDelete() {
        guard let node = pendingAdminDelete else { return }
        pendingAdminDelete = nil
        guard Self.isSafeToDelete(node.url) else { return }
        let quoted = "'" + node.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if let e = HiddenSpace.runAsAdmin("/bin/rm -rf \(quoted)") {
            errorMessage = "Couldn't delete “\(node.name)”: \(e)\n\nIf it says “Operation not permitted”, give Hierarchy Size Full Disk Access (sidebar › Permissions). Some files are protected by macOS and can't be deleted at all."
        }
        if FileManager.default.fileExists(atPath: node.path) {
            if errorMessage == nil {
                errorMessage = "Some files in “\(node.name)” couldn't be deleted. macOS protects them."
            }
            rescanAfterPartialDelete(node)
        } else {
            removeFromTree(node)
        }
    }

    private func removeFromTree(_ node: FileNode) {
        if let f = focus, f.isDescendant(of: node) { focus = node.parent }
        if let s = selection, s.isDescendant(of: node) { selection = nil }
        node.detachFromParent()
        searchResults.removeAll { $0.isDescendant(of: node) }
        revision += 1
        recomputeStats()
        refreshVolumes()
        refreshTrash()
    }

    private func rescanAfterPartialDelete(_ node: FileNode) {
        if let r = root { scan(r.url) } else { refreshVolumes() }
    }

    /// Never offer permanent deletion of the system or of top-level folders.
    static func isSafeToDelete(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let home = AppModel.userHome.path
        let blocked = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin",
                       "/etc", "/var", "/Volumes", "/opt", home, home + "/Library", home + "/Documents",
                       home + "/Desktop", home + "/Downloads", home + "/Pictures", home + "/Movies", home + "/Music"]
        if blocked.contains(p) { return false }
        if p.hasPrefix("/System/") && !p.hasPrefix("/System/Volumes/Data/") { return false }
        return url.pathComponents.count > 2
    }

    // MARK: Trash & permissions

    func refreshTrash() {
        Task.detached(priority: .utility) {
            let trash = AppModel.userHome.appendingPathComponent(".Trash")
            var total: Int64 = 0
            var readable = true
            var count = 0
            do {
                let items = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
                count = items.count
                let e = FileManager.default.enumerator(at: trash, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                while let u = e?.nextObject() as? URL {
                    total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                }
            } catch { readable = false }
            let fda = Self.hasFullDiskAccess()
            let (t, r, c) = (total, readable, count)
            await MainActor.run {
                self.trashSize = r ? t : nil
                self.trashCount = c
                self.hasFullDiskAccess = fda
            }
        }
    }

    /// Full Disk Access is granted when TCC-protected locations can be listed.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let home = AppModel.userHome
        let probes = [home.appendingPathComponent("Library/Safari"),
                      home.appendingPathComponent("Library/Mail"),
                      home.appendingPathComponent(".Trash"),
                      URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC")]
        for p in probes where FileManager.default.fileExists(atPath: p.path) {
            if (try? FileManager.default.contentsOfDirectory(atPath: p.path)) != nil { return true }
            return false
        }
        return false
    }

    func emptyTrash() {
        if Self.isRoot {
            // Finder belongs to the normal user, so empty that user's Trash directly.
            let trash = Self.userHome.appendingPathComponent(".Trash")
            var failed = 0
            for item in (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [] {
                do { try FileManager.default.removeItem(at: item) } catch { failed += 1 }
            }
            if failed > 0 { errorMessage = "\(failed) items in the Trash couldn't be deleted. macOS protects them." }
            refreshTrash(); refreshVolumes()
            return
        }
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
            errorMessage = "Couldn't empty the Trash: \(err[NSAppleScript.errorMessage] as? String ?? "unknown error"). Allow Hierarchy Size to control Finder in System Settings › Privacy & Security › Automation."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshTrash(); self.refreshVolumes() }
    }

    func openPrivacySettings(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Administrator mode

    nonisolated static let isRoot = getuid() == 0

    /// The real user's home, also when running as root (passed in by `runAsAdministrator`).
    nonisolated static var userHome: URL {
        if isRoot, let h = ProcessInfo.processInfo.environment["HS_USER_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated static func moveToUserTrash(_ url: URL) throws {
        let trash = userHome.appendingPathComponent(".Trash")
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var dest = trash.appendingPathComponent(url.lastPathComponent)
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = trash.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        try FileManager.default.moveItem(at: url, to: dest)
    }

    static let skipAdminPromptKey = "skipAdminPrompt"

    /// Relaunches Hierarchy Size as root after one password prompt, then quits this copy.
    func runAsAdministrator() {
        guard !Self.isRoot, let bin = Bundle.main.executablePath else { return }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "HS_USER_HOME=\(q(Self.userHome.path)) \(q(bin)) > /dev/null 2>&1 &"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) != -128 {
                errorMessage = "Couldn't start as administrator: \(err[NSAppleScript.errorMessage] as? String ?? "unknown error")"
            }
            return
        }
        NSApp.terminate(nil)
    }

    /// Relaunch so newly granted permissions take effect.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
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
