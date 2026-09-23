import Foundation

/// One Claude Code session's live stats, written by fleet's HUD statusline script
/// to ~/.config/fleet/sessions/<id>.json.
struct SessionStat: Decodable {
    var sessionId: String
    var dir: String
    var model: String?
    var costUsd: Double?
    var ctxPct: Int?
    var rl5h: Int?      // 5-hour rate-limit used %, from Claude Code's statusLine hook
    var rl7d: Int?      // 7-day rate-limit used %
    var attention: Bool?
    var state: String?
    var updated: Double?
    // Added alongside the null-vs-zero fix and pane-id matching (see match's
    // doc comment): a sidecar without these is from before this existed, and
    // decodes fine with them all nil — hudVersion nil in particular is the
    // signal that a sidecar predates real null-vs-0 handling.
    var claudePid: Int?
    var hudVersion: Int?
    var fleetPaneId: String?
    var account: String?
    var configDir: String?
}

enum SessionStats {
    static var dir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("fleet/sessions")
    }

    /// One directory scan + decode of every sidecar. O(S). Callers that need
    /// to match many panes against this should call it ONCE per pass and
    /// reuse the result — never call this per-pane in a loop (that's O(P×S)
    /// and is exactly the kind of thing that falls over once a fleet has
    /// been used for weeks and the sessions folder has hundreds of files).
    static func all() -> [SessionStat] { load(maxAgeHours: 8) }

    /// Sidecars updated within the last `maxAgeHours`.
    static func load(maxAgeHours: Double) -> [SessionStat] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let now = Date().timeIntervalSince1970
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SessionStat.self, from: Data(contentsOf: $0)) }
            .filter { now - ($0.updated ?? 0) < maxAgeHours * 3600 }
    }

    /// Best match for `path` out of an already-loaded snapshot (see `all()`).
    /// Matches a sidecar to a SPECIFIC pane by `fleetPaneId` — set by
    /// TerminalPane via the FLEET_PANE_ID env var, and written into the
    /// sidecar by hud/statusline.sh. This used to match by the pane's
    /// working directory instead (exact path, its symlink target, or just
    /// the last path component) — meaning two panes in the SAME directory
    /// always showed identical numbers (whichever session most recently
    /// wrote to that dir), a brand-new pane could show a stale reading from
    /// a session that ran there hours ago (inside Fleet or not), and any
    /// two unrelated directories sharing a basename anywhere on disk could
    /// collide. A pane with no sidecar of its own now shows nothing (nil),
    /// never another pane's borrowed numbers.
    static func match(_ stats: [SessionStat], paneID: UUID) -> SessionStat? {
        let idStr = paneID.uuidString
        return stats
            .filter { $0.fleetPaneId == idStr }
            .max { ($0.updated ?? 0) < ($1.updated ?? 0) }
    }

    static func totalCostToday(_ stats: [SessionStat]? = nil) -> Double {
        let cutoff = Date().timeIntervalSince1970 - 86_400
        return (stats ?? all()).filter { ($0.updated ?? 0) > cutoff }.reduce(0) { $0 + ($1.costUsd ?? 0) }
    }

    /// Bounds disk growth — sidecars older than this are deleted outright
    /// (not just filtered at read time). Call occasionally, not every poll.
    static func pruneOlderThan(days: Int = 30) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let stat = try? JSONDecoder().decode(SessionStat.self, from: data),
                  (stat.updated ?? 0) < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
