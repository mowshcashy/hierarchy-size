import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HierarchySizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Hierarchy Size") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan") { model.rescan() }.keyboardShortcut("r")
                Divider()
                Button("Export as CSV…") { model.exportCSV() }.keyboardShortcut("e")
                Divider()
                Button(AppModel.isRoot ? "Running as Administrator" : "Run as Administrator…") { model.runAsAdministrator() }
                    .disabled(AppModel.isRoot)
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") { model.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Top of Scan") { if let r = model.root { model.setFocus(r) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Hidden Space…") { model.showHiddenSpace = true }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Reveal Selection in Finder") { if let s = model.selection { model.reveal(s) } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Move Selection to Trash…") { if let s = model.selection { model.requestTrash(s) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Delete Selection Immediately…") { if let s = model.selection { model.requestDeleteNow(s) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                Divider()
                Button("Empty Trash") { model.emptyTrash() }
                Button("Permissions…") { model.showPermissions = true }
            }
            CommandMenu("View") {
                ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { i, t in
                    Button(t.rawValue) { model.tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }
}
