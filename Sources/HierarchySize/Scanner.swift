import Foundation

/// Thread-safe live counters shared between the scanning threads and the UI.
final class ScanProgress: @unchecked Sendable {
    struct Snapshot {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0
        var errors = 0
        var currentPath = ""
    }

    private let lock = NSLock()
    private var s = Snapshot()
    private var cancelled = false

    func add(files: Int, folders: Int, bytes: Int64, path: String) {
        lock.lock()
        s.files += files; s.folders += folders; s.bytes += bytes; s.currentPath = path
        lock.unlock()
    }
    func addError() { lock.lock(); s.errors += 1; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return s }
}

/// Recursively scans a folder into a FileNode tree. Top levels are scanned in parallel.
struct Scanner {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
    ]
    static let keySet = Set(keys)

    let progress: ScanProgress
    /// Folders never descended into (avoids double counting APFS firmlinks and other volumes when scanning "/").
    let excluded: Set<String>

    init(root: URL, progress: ScanProgress) {
        self.progress = progress
        var ex: Set<String> = []
        if root.path == "/" {
            ex = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/net", "/home",
                  "/.nofollow", "/.resolve", "/.vol", "/.Spotlight-V100", "/.fseventsd"]
        }
        // Never descend into the hidden root aliases, whatever the scan root is.
        ex.formUnion(["/.nofollow", "/.resolve", "/.vol"])
        self.excluded = ex
    }

    func scan(root: URL) -> FileNode {
        let name = (try? root.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? root.lastPathComponent
        let node = FileNode(url: root, name: name.isEmpty ? root.path : name, isDirectory: true)
        node.modified = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        scanDirectory(node, depth: 0)
        return node
    }

    private func scanDirectory(_ node: FileNode, depth: Int) {
        if progress.isCancelled { return }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: node.url, includingPropertiesForKeys: Self.keys, options: [])
        } catch {
            node.isUnreadable = true
            progress.addError()
            return
        }

        var children: [FileNode] = []
        children.reserveCapacity(entries.count)
        var subdirs: [FileNode] = []
        var fileBytes: Int64 = 0
        var files = 0

        for u in entries {
            guard let v = try? u.resourceValues(forKeys: Self.keySet) else { continue }
            let isLink = v.isSymbolicLink ?? false
            let isDir = (v.isDirectory ?? false) && !isLink
            if isDir {
                var p = u.path
                while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                if excluded.contains(p) { continue }
            }
            let child = FileNode(url: u, name: u.lastPathComponent, isDirectory: isDir)
            child.parent = node
            child.modified = v.contentModificationDate
            if isDir {
                subdirs.append(child)
            } else {
                child.logicalSize = Int64(v.fileSize ?? 0)
                child.allocatedSize = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                fileBytes += child.allocatedSize
                files += 1
            }
            children.append(child)
        }
        progress.add(files: files, folders: subdirs.count, bytes: fileBytes, path: node.url.path)

        if depth < 3 && subdirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                scanDirectory(subdirs[i], depth: depth + 1)
            }
        } else {
            for d in subdirs { scanDirectory(d, depth: depth + 1) }
        }

        var logical: Int64 = 0, allocated: Int64 = 0, fc = 0, dc = 0
        var newest = node.modified
        for c in children {
            logical += c.logicalSize
            allocated += c.allocatedSize
            if c.isDirectory { fc += c.fileCount; dc += c.folderCount + 1 } else { fc += 1 }
            if let m = c.modified, m > (newest ?? .distantPast) { newest = m }
        }
        node.logicalSize = logical
        node.allocatedSize = allocated
        node.fileCount = fc
        node.folderCount = dc
        node.modified = newest
        node.children = children
    }
}

// MARK: - Statistics

struct ExtensionStat: Identifiable {
    let ext: String
    var size: Int64
    var count: Int
    var id: String { ext }
    var label: String { ext.isEmpty ? "(no extension)" : "." + ext }
    var category: FileCategory { FileCategory.of(ext) }
}

struct CategoryStat: Identifiable {
    let category: FileCategory
    var size: Int64
    var count: Int
    var id: String { category.rawValue }
}

struct AgeBucket: Identifiable {
    let label: String
    let maxAge: TimeInterval
    var size: Int64 = 0
    var count = 0
    var id: String { label }
}

struct ScanStats {
    var extensions: [ExtensionStat] = []
    var categories: [CategoryStat] = []
    var topFiles: [FileNode] = []
    var ages: [AgeBucket] = []
    var totalFiles = 0

    static func compute(root: FileNode, mode: SizeMode, topCount: Int = 250) -> ScanStats {
        var ext: [String: ExtensionStat] = [:]
        var cats: [FileCategory: CategoryStat] = [:]
        let day: TimeInterval = 86_400
        var ages = [
            AgeBucket(label: "< 1 month", maxAge: 30 * day),
            AgeBucket(label: "1–6 months", maxAge: 182 * day),
            AgeBucket(label: "6–12 months", maxAge: 365 * day),
            AgeBucket(label: "1–2 years", maxAge: 730 * day),
            AgeBucket(label: "2–5 years", maxAge: 1826 * day),
            AgeBucket(label: "> 5 years", maxAge: .infinity),
        ]
        var top: [FileNode] = []
        var threshold: Int64 = -1
        var total = 0
        let now = Date()

        var stack: [FileNode] = [root]
        while let n = stack.popLast() {
            if n.isDirectory { stack.append(contentsOf: n.children); continue }
            total += 1
            let s = n.size(mode)
            let e = n.fileExtension
            ext[e, default: ExtensionStat(ext: e, size: 0, count: 0)].size += s
            ext[e]!.count += 1
            let c = FileCategory.of(e)
            cats[c, default: CategoryStat(category: c, size: 0, count: 0)].size += s
            cats[c]!.count += 1
            let age = now.timeIntervalSince(n.modified ?? now)
            if let i = ages.firstIndex(where: { age < $0.maxAge }) {
                ages[i].size += s; ages[i].count += 1
            }
            if s > threshold {
                top.append(n)
                if top.count >= topCount * 2 {
                    top.sort { $0.size(mode) > $1.size(mode) }
                    top.removeLast(top.count - topCount)
                    threshold = top.last!.size(mode)
                }
            }
        }
        top.sort { $0.size(mode) > $1.size(mode) }
        if top.count > topCount { top.removeLast(top.count - topCount) }

        var st = ScanStats()
        st.extensions = ext.values.sorted { $0.size > $1.size }
        st.categories = cats.values.sorted { $0.size > $1.size }
        st.topFiles = top
        st.ages = ages
        st.totalFiles = total
        return st
    }
}
