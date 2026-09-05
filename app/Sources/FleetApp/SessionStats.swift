import Foundation

/// One Claude Code session's live stats, written by fleet's HUD statusline script
/// to ~/.config/fleet/sessions/<id>.json.
struct SessionStat: Decodable {
    var sessionId: String
    var dir: String
    var model: String?
    var costUsd: Double?
    var ctxPct: Int?
    var attention: Bool?
    var state: String?
    var updated: Double?
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
    static func all() -> [SessionStat] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let now = Date().timeIntervalSince1970
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SessionStat.self, from: Data(contentsOf: $0)) }
            .filter { now - ($0.updated ?? 0) < 8 * 3600 }
    }

    /// Best match for `path` out of an already-loaded snapshot (see `all()`).
    static func match(_ stats: [SessionStat], path: String) -> SessionStat? {
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
        let base = (path as NSString).lastPathComponent
        return stats
            .filter { $0.dir == path || $0.dir == real || ($0.dir as NSString).lastPathComponent == base }
            .max { ($0.updated ?? 0) < ($1.updated ?? 0) }
    }

    /// Convenience for one-off lookups outside a poll loop. Do not use this
    /// in a per-pane loop — see `all()`.
    static func forPath(_ path: String) -> SessionStat? { match(all(), path: path) }

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
