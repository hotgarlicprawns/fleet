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

    static func all() -> [SessionStat] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let now = Date().timeIntervalSince1970
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SessionStat.self, from: Data(contentsOf: $0)) }
            .filter { now - ($0.updated ?? 0) < 8 * 3600 }
    }

    /// Best-matching session for a working directory (exact real path, else basename).
    static func forPath(_ path: String) -> SessionStat? {
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
        let base = (path as NSString).lastPathComponent
        return all()
            .filter { $0.dir == path || $0.dir == real || ($0.dir as NSString).lastPathComponent == base }
            .sorted { ($0.updated ?? 0) > ($1.updated ?? 0) }
            .first
    }

    static func totalCostToday() -> Double {
        let cutoff = Date().timeIntervalSince1970 - 86_400
        return all().filter { ($0.updated ?? 0) > cutoff }.reduce(0) { $0 + ($1.costUsd ?? 0) }
    }
}
