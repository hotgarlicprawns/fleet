import Foundation

/// A GUI app launched by LaunchServices inherits a minimal PATH, so `claude`
/// (installed via nvm/homebrew) isn't found. Resolve the real login PATH once
/// at startup — never lazily from a view body, which deadlocks the main thread.
enum UserEnv {
    static let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    nonisolated(unsafe) static var path: String =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Call once, early, off the SwiftUI render path.
    static func resolve() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // login shell, but also pull in an interactive rc (nvm lives there) — non-interactively
        // rc files may print banners to stdout, so tag the line we want and grep it out
        p.arguments = ["-lc", "{ [ -f ~/.zshrc ] && source ~/.zshrc; } >/dev/null 2>&1; printf 'FLEETPATH=%s\\n' \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            // hard timeout so a misbehaving rc can never hang launch
            let deadline = DispatchTime.now() + 4
            DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let out = String(data: data, encoding: .utf8),
               let line = out.split(separator: "\n").last(where: { $0.hasPrefix("FLEETPATH=") }) {
                let s = String(line.dropFirst("FLEETPATH=".count))
                if s.contains("/") { path = s }
            }
        } catch { }
        // make sure nvm's current node bin is present even if the rc probe missed it
        let nvm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvm.path).sorted().last {
            let bin = nvm.appendingPathComponent("\(vers)/bin").path
            if !path.split(separator: ":").contains(Substring(bin)) { path = "\(bin):\(path)" }
        }
    }

    /// Rewrite a command so its leading binary is an absolute path from the
    /// resolved PATH — belt-and-braces for GUI launches with a stripped env.
    static func resolveCommand(_ command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let bin = parts.first, !bin.hasPrefix("/"), !bin.contains("$") else { return command }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(bin)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return parts.count > 1 ? "\(candidate) \(parts[1])" : candidate
            }
        }
        return command
    }
}
