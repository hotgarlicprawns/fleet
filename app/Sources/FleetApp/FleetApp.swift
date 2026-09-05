import SwiftUI
import AppKit

/// Debug log under ~/.config/fleet/ — not the home directory root. Cheap, and
/// harmless to leave in for a v0.1: only ever written to, never read by the UI.
func flog(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/fleet")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("app-debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

@main
struct FleetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = CockpitStore()

    var body: some Scene {
        Window("fleet", id: "cockpit") {
            CockpitView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                Button("Jump to Next Waiting") { store.jumpToWaiting() }
                    .keyboardShortcut("j", modifiers: [.command])
                Button("Add Pane") {
                    if let s = store.activeScreen { store.setPaneCount(s.panes.count + 1, in: s.id) }
                }.keyboardShortcut("t", modifiers: [.command])
                Button("Remove Pane") {
                    if let s = store.activeScreen { store.setPaneCount(s.panes.count - 1, in: s.id) }
                }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // must happen before SwiftUI stands up its scenes, or WindowGroup/Window
        // can decide there's nothing to show and create zero windows.
        NSApp.setActivationPolicy(.regular)
        UserEnv.resolve()
        flog("applicationWillFinishLaunching; PATH=\(UserEnv.path.prefix(80))")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        flog("applicationDidFinishLaunching; windows=\(NSApp.windows.count)")
        NSApp.activate(ignoringOtherApps: true)
        Task { await ensureWindow(attempt: 0) }
    }
    private func ensureWindow(attempt: Int) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        for w in NSApp.windows where w.title.isEmpty && w.contentView?.subviews.isEmpty != false {
            w.close()
        }
        if let main = NSApp.windows.first {
            main.makeKeyAndOrderFront(nil)
            main.setContentSize(NSSize(width: 1100, height: 700))
            main.center()
            flog("window ready after attempt \(attempt): \(main.title)")
        } else if attempt < 5 {
            flog("no window yet (attempt \(attempt)) — retrying")
            await ensureWindow(attempt: attempt + 1)
        } else {
            flog("giving up waiting for a window")
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
