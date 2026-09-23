import SwiftUI
import AppKit

/// Debug log under $XDG_CONFIG_HOME/fleet (or ~/.config/fleet if unset) — same
/// override every other config path in this app respects (CockpitStore,
/// LicenseManager, SessionStats, HUDManager). This one was hardcoded to the
/// real home directory, which meant a test run isolated via XDG_CONFIG_HOME
/// still wrote its debug log into the real ~/.config/fleet — harmless on its
/// own, but a sign the isolation wasn't actually complete. Cheap, and
/// harmless to leave in for a v0.1: only ever written to, never read by the UI.
func flog(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    let dir = base.appendingPathComponent("fleet")
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
                .frame(minWidth: 1040, minHeight: 600)
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
                Button("Remove Last Pane") {
                    // TODO once focused-pane tracking exists (see PaneCell's
                    // per-pane × for the general case): this should close
                    // whichever pane has keyboard focus, not always the last
                    // one. Routed through closePane (not setPaneCount) so it
                    // gets the same maximizedPane/statByPane cleanup.
                    if let s = store.activeScreen, let last = s.panes.last { store.closePane(last.id, in: s.id) }
                }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // must happen before SwiftUI stands up its scenes, or WindowGroup/Window
        // can decide there's nothing to show and create zero windows.
        NSApp.setActivationPolicy(.regular)
        UserEnv.resolve()
        flog("applicationWillFinishLaunching; PATH=\(UserEnv.path.prefix(80))")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        flog("applicationDidFinishLaunching; windows=\(NSApp.windows.count)")
        flog("hotkey ⌃⌥F registered: \(Hotkey.register { Hotkey.summon() })")
        NSApp.activate(ignoringOtherApps: true)
        Task { await ensureWindow(attempt: 0) }
    }
    private func ensureWindow(attempt: Int) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Pick the main window by title. NSApp.windows also holds the menu-bar
        // status item's window, and its position in the list is not stable —
        // taking `.first` sometimes configured the wrong one.
        if let main = NSApp.windows.first(where: { $0.title == "fleet" }) {
            main.delegate = self
            main.makeKeyAndOrderFront(nil)
            main.setContentSize(NSSize(width: 1100, height: 700))
            main.center()
            flog("window ready after attempt \(attempt): \(main.title)")
        } else if attempt < 8 {
            flog("no main window yet (attempt \(attempt)) — retrying")
            await ensureWindow(attempt: attempt + 1)
        } else {
            flog("giving up waiting for the main window")
        }
    }
    // The window's close button hides it instead: closing would tear the terminals
    // down and stop every agent. Fleet lives in the menu bar; ⌃⌥F or the menu
    // bar item brings the window back, and ⌘Q quits for real.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Hotkey.summon() }
        return true
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var store: CockpitStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let waiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
        HStack(spacing: 3) {
            Image(systemName: waiting > 0 ? "square.grid.2x2.fill" : "square.grid.2x2")
            if waiting > 0 { Text("\(waiting)") }
        }
        // Self-heal: this label exists from launch. If SwiftUI did not open the
        // main window (seen intermittently), open it explicitly.
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if NSApp.windows.first(where: { $0.title == "fleet" }) == nil {
                flog("main window missing after launch — opening it explicitly")
                openWindow(id: "cockpit")
            }
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        let waiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
        Text(String(format: "$%.2f today · %d pane%@ · %@", store.totalToday, store.totalPanes,
                    store.totalPanes == 1 ? "" : "s", store.entitlement.label))
        if waiting > 0 { Button("Jump to waiting (\(waiting))") { store.jumpToWaiting(); Hotkey.summon() } }
        Divider()
        ForEach(store.screens) { s in
            Button((s.id == store.activeScreenID ? "● " : "   ") + s.name + (store.waitingCount(s) > 0 ? "  · waiting" : "")) {
                store.select(s.id); Hotkey.summon()
            }
        }
        Divider()
        Button("Show Fleet   ⌃⌥F") { Hotkey.summon() }
        Button("Quit Fleet") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
