import SwiftUI
import AppKit
import SwiftTerm

/// A single Claude Code session as a real terminal (SwiftTerm PTY).
struct TerminalPane: NSViewRepresentable {
    let pane: PaneConfig
    @Binding var focusRequest: UUID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
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
        term.startProcess(executable: shell,
                          args: ["-c", "cd '\(dir)' && exec \(cmd)"],
                          environment: env)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if focusRequest == pane.id {
            nsView.window?.makeFirstResponder(nsView)
            DispatchQueue.main.async { self.focusRequest = nil }
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            flog("processTerminated exit=\(String(describing: exitCode))")
            if let t = source as? LocalProcessTerminalView {
                let msg = "\r\n\u{1b}[2m[process exited\(exitCode.map { " · \($0)" } ?? "")]  press ⏎ to restart\u{1b}[0m\r\n"
                t.feed(text: msg)
            }
        }
    }
}
