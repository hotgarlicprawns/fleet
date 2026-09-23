import SwiftUI
import AppKit
import SwiftTerm

/// A single agent session as a real terminal (SwiftTerm PTY).
struct TerminalPane: NSViewRepresentable {
    let pane: PaneConfig
    @Binding var focusRequest: UUID?
    /// Overrides pane.command for this launch only (used by Resume).
    var command: String? = nil
    var onExit: @MainActor @Sendable (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        context.coordinator.onExit = onExit
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        term.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        term.nativeBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        term.nativeForegroundColor = NSColor(calibratedWhite: 0.86, alpha: 1)

        let shell = UserEnv.shell
        let dir = pane.cwd.replacingOccurrences(of: "'", with: "'\\''")
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.removeAll { $0.hasPrefix("PATH=") || $0.hasPrefix("SHELL=") }
        env.append("PATH=\(UserEnv.path)")
        env.append("SHELL=\(shell)")
        env.append("FLEET_PANE=\(pane.name)")
        // Inherited by hud/statusline.sh and the fleet-lean MCP server (both
        // spawned as children of this `claude` process), so they can key
        // their own sidecars by the exact pane, not by directory/basename —
        // see SessionStats.match's doc comment for why that used to be wrong.
        env.append("FLEET_PANE_ID=\(pane.id.uuidString)")
        if !env.contains(where: { $0.hasPrefix("HOME=") }) {
            env.append("HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        }
        let cmd = UserEnv.resolveCommand(command ?? pane.command)
        flog("TerminalPane.makeNSView pane=\(pane.name) cmd=\(cmd)")
        // No `exec`: pane.command can be any shell text — a bare program
        // ("claude"), one with args, or a compound one-liner. `exec` only
        // parses a single simple command; anything with ;/&&/| fails with a
        // silent exit 127. Running it as the shell's last statement handles
        // every shape, at the cost of one extra process in the tree.
        term.startProcess(executable: shell,
                          args: ["-c", "cd '\(dir)' && \(cmd)"],
                          environment: env)
        return term
    }

    /// SwiftTerm's deinit closes the PTY but deliberately never kills the child,
    /// and since panes run without `exec` the agent is a *grandchild* of the
    /// shell — so killing only the shell would orphan it. The shell is its own
    /// session/process-group leader (forkpty), so signal the whole group.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        guard let pid = nsView.process?.shellPid, pid > 1 else { return }
        flog("dismantle: killing process group \(pid)")
        kill(-pid, SIGHUP)
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL) }
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        if focusRequest == pane.id {
            nsView.window?.makeFirstResponder(nsView)
            DispatchQueue.main.async { self.focusRequest = nil }
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: @MainActor @Sendable (Int32?) -> Void
        init(onExit: @escaping @MainActor @Sendable (Int32?) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            flog("processTerminated exit=\(String(describing: exitCode))")
            if let t = source as? LocalProcessTerminalView {
                let code = exitCode.map { " · exit \($0)" } ?? ""
                t.feed(text: "\r\n\u{1b}[2m[process ended\(code)]\u{1b}[0m\r\n")
            }
            let handler = onExit
            Task { @MainActor in handler(exitCode) }
        }
    }
}
