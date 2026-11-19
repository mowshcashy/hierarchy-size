import AppKit
import Foundation
import SwiftUI

// MARK: - Data

struct SnapshotInfo: Identifiable {
    let uuid: String
    let name: String
    let mountPoint: String
    let purgeable: Bool
    let limitsShrink: Bool
    var id: String { uuid }

    var isTimeMachine: Bool { name.hasPrefix("com.apple.TimeMachine.") }
    var isSystemUpdate: Bool { name.hasPrefix("com.apple.os.update-") }
    /// "2026-11-18-120000" for Time Machine snapshots.
    var timeMachineDate: String? {
        guard isTimeMachine else { return nil }
        let s = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        return s.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil ? s : nil
    }
    var canDelete: Bool { timeMachineDate != nil || (purgeable && !isSystemUpdate) }
    var displayName: String {
        if let d = timeMachineDate { return "Time Machine · \(d)" }
        if isSystemUpdate { return "macOS system snapshot" }
        return name
    }
}

struct APFSVolumeEntry: Identifiable {
    let device: String
    let name: String
    let role: String
    let consumed: Int64
    var snapshots: [SnapshotInfo] = []
    var id: String { device }

    var explanation: String {
        switch role {
        case "System": "macOS itself. Sealed and read-only, so it can't be reduced."
        case "Data": "Your files, apps, caches and settings. Scan it to see the details."
        case "VM": "Swap memory, used when RAM is full. Shrinks after closing heavy apps or restarting."
        case "Preboot": "Boot files and downloaded macOS update parts. Usually shrinks after updates install."
        case "Recovery": "macOS Recovery, used to repair or reinstall macOS."
        case "Update": "A staged macOS update waiting to be installed."
        default: role.isEmpty ? "Extra volume" : "\(role) volume"
        }
    }
    var color: Color {
        switch role {
        case "Data": Color(red: 0.25, green: 0.60, blue: 0.95)
        case "System": Color(red: 0.55, green: 0.60, blue: 0.68)
        case "VM": Color(red: 0.88, green: 0.30, blue: 0.40)
        case "Preboot": Color(red: 0.95, green: 0.55, blue: 0.25)
        case "Recovery": Color(red: 0.25, green: 0.75, blue: 0.60)
        default: Color(red: 0.70, green: 0.40, blue: 0.85)
        }
    }
}

struct DiskImageEntry: Identifiable {
    let imagePath: String
    let mountPoint: String?
    let sizeOnDisk: Int64
    var id: String { imagePath }
    var name: String { (imagePath as NSString).lastPathComponent }
    var isSimulatorRuntime: Bool { imagePath.contains("SimulatorRuntime") || (mountPoint?.contains("CoreSimulator") ?? false) }
    var isSystem: Bool { imagePath.hasPrefix("/System/") || imagePath.hasPrefix("/Library/") }
}

struct HiddenSpaceReport {
    var capacity: Int64 = 0
    var free: Int64 = 0
    var purgeable: Int64 = 0
    var volumes: [APFSVolumeEntry] = []
    var images: [DiskImageEntry] = []
    var snapshots: [SnapshotInfo] { volumes.flatMap(\.snapshots) }
}

// MARK: - Loading

enum HiddenSpace {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    static func plist(_ tool: String, _ args: [String]) -> [String: Any]? {
        let r = run(tool, args)
        guard r.status == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: r.out, format: nil)) as? [String: Any]
    }

    static func load() -> HiddenSpaceReport {
        var rep = HiddenSpaceReport()

        // Volumes of the container that holds macOS.
        if let list = plist("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
           let containers = list["Containers"] as? [[String: Any]] {
            let main = containers.first { c in
                ((c["Volumes"] as? [[String: Any]]) ?? []).contains { (($0["Roles"] as? [String]) ?? []).contains("System") }
            }
            if let c = main {
                rep.capacity = (c["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0
                rep.free = (c["CapacityFree"] as? NSNumber)?.int64Value ?? 0
                for v in (c["Volumes"] as? [[String: Any]]) ?? [] {
                    let roles = (v["Roles"] as? [String]) ?? []
                    rep.volumes.append(APFSVolumeEntry(
                        device: v["DeviceIdentifier"] as? String ?? "?",
                        name: v["Name"] as? String ?? "?",
                        role: roles.first ?? "",
                        consumed: (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0))
                }
                rep.volumes.sort { $0.consumed > $1.consumed }
            }
        }

        // Snapshots (need mount points).
        for (mount, role) in [("/", "System"), ("/System/Volumes/Data", "Data")] {
            guard let s = plist("/usr/sbin/diskutil", ["apfs", "listSnapshots", "-plist", mount]),
                  let snaps = s["Snapshots"] as? [[String: Any]],
                  let i = rep.volumes.firstIndex(where: { $0.role == role }) else { continue }
            rep.volumes[i].snapshots = snaps.map {
                SnapshotInfo(uuid: $0["SnapshotUUID"] as? String ?? UUID().uuidString,
                             name: $0["SnapshotName"] as? String ?? "?",
                             mountPoint: mount,
                             purgeable: ($0["Purgeable"] as? Bool) ?? false,
                             limitsShrink: ($0["LimitingContainerShrink"] as? Bool) ?? false)
            }
        }

        // Purgeable space macOS can free on demand.
        if let v = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let important = v.volumeAvailableCapacityForImportantUsage, let avail = v.volumeAvailableCapacity {
            rep.purgeable = max(0, important - Int64(avail))
        }

        // Mounted disk images: their files live on the disk.
        if let info = plist("/usr/bin/hdiutil", ["info", "-plist"]), let images = info["images"] as? [[String: Any]] {
            for img in images {
                guard let path = img["image-path"] as? String else { continue }
                let mount = ((img["system-entities"] as? [[String: Any]]) ?? []).compactMap { $0["mount-point"] as? String }.first
                let url = URL(fileURLWithPath: path)
                let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
                var size = Int64(vals?.totalFileAllocatedSize ?? 0)
                if vals?.isDirectory == true { size = directorySize(url) } // sparse bundles
                rep.images.append(DiskImageEntry(imagePath: path, mountPoint: mount, sizeOnDisk: size))
            }
            rep.images.sort { $0.sizeOnDisk > $1.sizeOnDisk }
        }
        return rep
    }

    private static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let u = e?.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Runs a command with an administrator password prompt. Returns an error message on failure.
    @MainActor
    static func runAsAdmin(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {   // -128 = user cancelled
            return err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        }
        return nil
    }
}

// MARK: - Model actions

extension AppModel {
    func loadHiddenSpace() {
        hiddenLoading = true
        Task.detached(priority: .userInitiated) {
            let r = HiddenSpace.load()
            await MainActor.run {
                self.hiddenReport = r
                self.hiddenLoading = false
            }
        }
    }

    func deleteSnapshot(_ s: SnapshotInfo) {
        let cmd: String
        if let date = s.timeMachineDate {
            cmd = "/usr/bin/tmutil deletelocalsnapshots \(date)"
        } else if s.canDelete, s.uuid.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil {
            cmd = "/usr/sbin/diskutil apfs deleteSnapshot '\(s.mountPoint)' -uuid \(s.uuid)"
        } else { return }
        if let e = HiddenSpace.runAsAdmin(cmd) { errorMessage = "Couldn't delete the snapshot: \(e)" }
        loadHiddenSpace(); refreshVolumes()
    }

    func deleteAllTimeMachineSnapshots() {
        if let e = HiddenSpace.runAsAdmin("/usr/bin/tmutil deletelocalsnapshots /") {
            errorMessage = "Couldn't delete the snapshots: \(e)"
        }
        loadHiddenSpace(); refreshVolumes()
    }

    func eject(_ img: DiskImageEntry) {
        guard let m = img.mountPoint else { return }
        let r = HiddenSpace.run("/usr/bin/hdiutil", ["detach", m])
        if r.status != 0 { errorMessage = "Couldn't eject “\(img.name)”. It may be in use." }
        loadHiddenSpace(); refreshVolumes()
    }
}

// MARK: - View

struct HiddenSpaceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingSnapshot: SnapshotInfo?
    @State private var confirmAllTM = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Hidden Space").font(Theme.display(30)).foregroundStyle(Theme.ink)
                Spacer()
                if model.hiddenLoading { ProgressView().controlSize(.small) }
                Button { model.loadHiddenSpace() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if let r = model.hiddenReport {
                ScrollView { content(r).padding(20) }
            } else {
                ProgressView("Reading your drive…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 640)
        .background(Theme.paper)
        .tint(Theme.accent)
        .onAppear { model.loadHiddenSpace() }
        .confirmationDialog("Delete this snapshot?", isPresented: Binding(get: { pendingSnapshot != nil }, set: { if !$0 { pendingSnapshot = nil } })) {
            Button("Delete Snapshot", role: .destructive) { if let s = pendingSnapshot { model.deleteSnapshot(s) }; pendingSnapshot = nil }
        } message: {
            Text("The older versions of files kept in “\(pendingSnapshot?.displayName ?? "")” will be gone for good. Your current files are not affected. macOS will ask for your password.")
        }
        .confirmationDialog("Delete all Time Machine local snapshots?", isPresented: $confirmAllTM) {
            Button("Delete All", role: .destructive) { model.deleteAllTimeMachineSnapshots() }
        } message: {
            Text("This frees the space they hold. Your backups on the Time Machine drive and your current files are not affected. macOS will ask for your password.")
        }
    }

    @ViewBuilder
    private func content(_ r: HiddenSpaceReport) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            // Overview bar
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Macintosh HD").font(.headline)
                    Spacer()
                    Text("\(r.free.bytesString) free of \(r.capacity.bytesString)").foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    HStack(spacing: 1) {
                        ForEach(r.volumes) { v in
                            Rectangle().fill(v.color)
                                .frame(width: max(0, g.size.width * CGFloat(Double(v.consumed) / Double(max(1, r.capacity)))))
                                .help("\(v.name): \(v.consumed.bytesString)")
                        }
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4))
                if r.purgeable > 0 {
                    Label("\(r.purgeable.bytesString) is purgeable: macOS frees it automatically when space is needed (caches, iCloud copies, snapshots).", systemImage: "sparkles")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            section("Volumes inside this drive", "Your drive is split into several volumes. Only “Data” holds your own files.") {
                ForEach(r.volumes) { v in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 3).fill(v.color).frame(width: 12, height: 12).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(v.name).bold()
                                if !v.role.isEmpty { Text(v.role).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                            }
                            Text(v.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(v.consumed.bytesString).monospacedDigit().bold()
                        if v.role == "Data" {
                            Button("Scan") { dismiss(); model.scan(URL(fileURLWithPath: "/System/Volumes/Data")) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            section("Snapshots", "Snapshots keep older versions of your files. They can hold on to space even after you delete files.") {
                if r.snapshots.isEmpty {
                    Label("No snapshots found. Nothing is hidden here.", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    ForEach(r.snapshots) { s in
                        HStack(spacing: 12) {
                            Image(systemName: s.isTimeMachine ? "clock.arrow.circlepath" : "camera.aperture")
                                .foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.displayName).bold()
                                Text(s.isSystemUpdate ? "Protected: macOS runs from this snapshot. It can't and shouldn't be removed."
                                     : s.isTimeMachine ? "Local Time Machine snapshot. Safe to delete."
                                     : s.purgeable ? "Purgeable snapshot made by an app." : "Protected snapshot.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if s.canDelete {
                                Button("Delete…", role: .destructive) { pendingSnapshot = s }
                            } else {
                                Image(systemName: "lock.fill").foregroundStyle(.tertiary).help("Protected by macOS")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if r.snapshots.contains(where: { $0.isTimeMachine }) {
                        Button("Delete All Time Machine Snapshots…", role: .destructive) { confirmAllTM = true }
                    }
                }
            }

            section("Mounted disk images", "Each mounted image is a file on your drive. Ejecting doesn't free space; deleting the image file does.") {
                if r.images.isEmpty {
                    Label("No disk images mounted.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(r.images) { img in
                    HStack(spacing: 12) {
                        Image(systemName: img.isSimulatorRuntime ? "iphone" : "opticaldiscdrive").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(img.isSimulatorRuntime ? "iOS Simulator runtime" : img.name).bold()
                            Text(img.isSimulatorRuntime
                                 ? "Used by Xcode to run iPhone apps. Remove it from Xcode › Settings › Components if you don't need it."
                                 : img.imagePath)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer()
                        Text(img.sizeOnDisk.bytesString).monospacedDigit().bold()
                        if !img.isSystem {
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: img.imagePath)]) }
                            if img.mountPoint != nil { Button("Eject") { model.eject(img) } }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func section<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.display(22)).foregroundStyle(Theme.ink)
            Text(subtitle).font(Theme.display(14).italic()).foregroundStyle(Theme.ink2)
            VStack(alignment: .leading, spacing: 4) { c() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ink).frame(height: 1) }
        }
    }
}
