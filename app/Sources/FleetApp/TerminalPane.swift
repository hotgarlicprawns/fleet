import SwiftUI
import AppKit
import SwiftTerm

/// A single agent session as a real terminal (SwiftTerm PTY).
struct TerminalPane: NSViewRepresentable {
    let pane: PaneConfig
    @Binding var focusRequest: UUID?
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
        if !env.contains(where: { $0.hasPrefix("HOME=") }) {
            env.append("HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        }
        let cmd = UserEnv.resolveCommand(pane.command)
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
