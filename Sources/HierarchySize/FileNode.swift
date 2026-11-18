import Foundation

enum SizeMode: String, CaseIterable, Identifiable {
    case allocated = "Size on Disk"
    case logical = "File Size"
    var id: String { rawValue }
}

enum SortKey: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case files = "Files"
    case modified = "Modified"
    var id: String { rawValue }
}

/// One file or folder in the scanned hierarchy.
final class FileNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var fileCount: Int = 0
    var folderCount: Int = 0
    var modified: Date?
    var children: [FileNode] = []
    weak var parent: FileNode?
    var isUnreadable = false

    init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }

    var id: FileNode { self }
    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    /// Children for outline views: nil for files and empty folders (no disclosure arrow).
    var outlineChildren: [FileNode]? { isDirectory && !children.isEmpty ? children : nil }

    var fileExtension: String { isDirectory ? "" : url.pathExtension.lowercased() }
    var path: String { url.path }
    var category: FileCategory { isDirectory ? .folder : FileCategory.of(fileExtension) }

    func size(_ mode: SizeMode) -> Int64 { mode == .allocated ? allocatedSize : logicalSize }

    /// Fraction of the parent's size (0...1).
    func fractionOfParent(_ mode: SizeMode) -> Double {
        guard let p = parent else { return 1 }
        let total = p.size(mode)
        return total > 0 ? Double(size(mode)) / Double(total) : 0
    }

    var ancestors: [FileNode] {
        var list: [FileNode] = []
        var n: FileNode? = self
        while let c = n { list.append(c); n = c.parent }
        return list.reversed()
    }

    func isDescendant(of other: FileNode) -> Bool {
        var n: FileNode? = self
        while let c = n { if c === other { return true }; n = c.parent }
        return false
    }

    /// Sorts the whole subtree in place (iterative, safe for deep trees).
    func sortRecursively(by key: SortKey, mode: SizeMode, ascending: Bool) {
        var stack: [FileNode] = [self]
        while let n = stack.popLast() {
            guard n.isDirectory, !n.children.isEmpty else { continue }
            n.children.sort { a, b in
                let r: Bool
                switch key {
                case .size:
                    let sa = a.size(mode), sb = b.size(mode)
                    r = sa == sb ? a.name.localizedStandardCompare(b.name) == .orderedAscending : sa > sb
                    return ascending ? !r : r
                case .name:
                    r = a.name.localizedStandardCompare(b.name) == .orderedAscending
                case .files:
                    r = a.fileCount > b.fileCount
                    return ascending ? !r : r
                case .modified:
                    r = (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
                    return ascending ? !r : r
                }
                return ascending ? r : !r
            }
            stack.append(contentsOf: n.children)
        }
    }

    /// Removes this node from the tree and updates all ancestor totals.
    func detachFromParent() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        let files = isDirectory ? fileCount : 1
        let folders = isDirectory ? folderCount + 1 : 0
        var a: FileNode? = p
        while let n = a {
            n.logicalSize -= logicalSize
            n.allocatedSize -= allocatedSize
            n.fileCount -= files
            n.folderCount -= folders
            a = n.parent
        }
        parent = nil
    }
}

enum FileCategory: String, CaseIterable, Identifiable {
    case folder = "Folder"
    case image = "Images"
    case video = "Video"
    case audio = "Audio"
    case document = "Documents"
    case code = "Code"
    case archive = "Archives"
    case app = "Apps & Libraries"
    case data = "Data"
    case other = "Other"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox"
        case .app: "app.dashed"
        case .data: "cylinder.split.1x2"
        case .other: "doc"
        }
    }

    private static let map: [String: FileCategory] = {
        var m: [String: FileCategory] = [:]
        func add(_ c: FileCategory, _ exts: String) { for e in exts.split(separator: " ") { m[String(e)] = c } }
        add(.image, "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 cr3 nef arw dng psd svg ico icns avif")
        add(.video, "mov mp4 m4v avi mkv wmv flv webm mpg mpeg 3gp mts prproj fcpbundle")
        add(.audio, "mp3 m4a aac wav aiff aif flac ogg wma alac caf logicx band")
        add(.document, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md csv odt ods epub")
        add(.code, "swift m h c cpp hpp js ts jsx tsx py rb go rs java kt php html css scss json xml yml yaml sh sql plist")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz dmg iso pkg xip")
        add(.app, "app dylib framework so a o bundle kext appex car nib storyboardc")
        add(.data, "db sqlite sqlite3 sqlitedb store realm log cache dat bin vmdk vdi qcow2 sparseimage sparsebundle")
        return m
    }()

    static func of(_ ext: String) -> FileCategory { map[ext] ?? .other }
}

extension Int64 {
    var bytesString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
