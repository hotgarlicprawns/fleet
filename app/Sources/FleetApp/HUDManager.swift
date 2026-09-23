import Foundation

/// Installs fleet's cost/context/rate-limit HUD into Claude Code, natively —
/// so a first-time user doesn't need the CLI at all. Mirrors `fleet hud
/// install`/`uninstall` in bin/fleet.js exactly (same paths, same
/// previous-statusLine preservation) so the two stay interchangeable.
enum HUDManager {
    private static var configDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("fleet")
    }
    private static var installedScript: URL { configDir.appendingPathComponent("statusline.sh") }
    private static var previousStatusLineFile: URL { configDir.appendingPathComponent("previous-statusline.json") }
    private static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The script ships two ways: bundled as an app Resource (a real .app),
    /// or alongside the source tree during `swift run` in development.
    private static var bundledScript: URL? {
        if let r = Bundle.main.url(forResource: "hud-statusline", withExtension: "sh") { return r }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("hud/statusline.sh")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static var isInstalled: Bool {
        guard let obj = readJSON(claudeSettings), let sl = obj["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd.contains("fleet")
    }

    @discardableResult
    static func install() -> String {
        guard let src = bundledScript else { return "couldn't find the HUD script bundled in the app" }
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: installedScript.path) {
                try FileManager.default.removeItem(at: installedScript)
            }
            try FileManager.default.copyItem(at: src, to: installedScript)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScript.path)

            var settings = readJSON(claudeSettings) ?? [:]
            if let existing = settings["statusLine"] as? [String: Any],
               let cmd = existing["command"] as? String, !cmd.contains("fleet") {
                writeJSON(previousStatusLineFile, existing)
            }
            settings["statusLine"] = ["type": "command", "command": installedScript.path, "padding": 0]
            try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            writeJSON(claudeSettings, settings)
            try FileManager.default.createDirectory(at: configDir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            return "installed"
        } catch { return error.localizedDescription }
    }

    /// Re-copies the bundled statusline.sh over the installed one if they
    /// differ, but ONLY if the HUD is already installed — never installs it
    /// for someone who hasn't opted in. Without this, `install()` only ever
    /// runs once (when the user clicks "Turn on HUD"), so every fix or
    /// field added to statusline.sh since then — the null-vs-0 handling and
    /// claudePid/fleetPaneId fields, for one — silently never reached an
    /// existing install. Cheap (one byte comparison); call it once at
    /// startup, not on a timer.
    @discardableResult
    static func upgradeIfStale() -> Bool {
        guard isInstalled, let src = bundledScript,
              FileManager.default.fileExists(atPath: installedScript.path) else { return false }
        guard let newData = try? Data(contentsOf: src),
              let oldData = try? Data(contentsOf: installedScript),
              newData != oldData else { return false }
        do {
            try FileManager.default.removeItem(at: installedScript)
            try FileManager.default.copyItem(at: src, to: installedScript)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScript.path)
            return true
        } catch { return false }
    }

    @discardableResult
    static func uninstall() -> String {
        var settings = readJSON(claudeSettings) ?? [:]
        if let previous = readJSON(previousStatusLineFile) {
            settings["statusLine"] = previous
            try? FileManager.default.removeItem(at: previousStatusLineFile)
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        writeJSON(claudeSettings, settings)
        return "removed"
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func writeJSON(_ url: URL, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }
}
