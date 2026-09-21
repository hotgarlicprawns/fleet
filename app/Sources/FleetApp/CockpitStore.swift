import SwiftUI
import AppKit

struct PaneConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var cwd: String

    enum CodingKeys: String, CodingKey { case id, name, command, cwd }

    init(name: String, command: String, cwd: String) {
        self.name = name; self.command = command; self.cwd = cwd
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = (try? c.decode(String.self, forKey: .command)) ?? "claude"
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

/// One independent workspace: its own terminal grid, and — when created from a
/// repo — its own git worktree/branch, so agents in different screens never
/// touch the same working tree.
struct Screen: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var repoPath: String?
    var worktreePath: String?
    var branch: String?
    var baseBranch: String = "main"
    var panes: [PaneConfig]

    var isGitBacked: Bool { worktreePath != nil }

    enum CodingKeys: String, CodingKey { case id, name, repoPath, worktreePath, branch, baseBranch, panes }

    init(id: UUID = UUID(), name: String, repoPath: String? = nil, worktreePath: String? = nil,
         branch: String? = nil, baseBranch: String = "main", panes: [PaneConfig]) {
        self.id = id; self.name = name; self.repoPath = repoPath; self.worktreePath = worktreePath
        self.branch = branch; self.baseBranch = baseBranch; self.panes = panes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "screen"
        repoPath = try? c.decode(String.self, forKey: .repoPath)
        worktreePath = try? c.decode(String.self, forKey: .worktreePath)
        branch = try? c.decode(String.self, forKey: .branch)
        baseBranch = (try? c.decode(String.self, forKey: .baseBranch)) ?? "main"
        panes = (try? c.decode([PaneConfig].self, forKey: .panes)) ?? []
    }
}

struct DisplayInfo: Identifiable, Hashable {
    var id: CGDirectDisplayID
    var name: String
    var isMain: Bool
}

@MainActor
final class CockpitStore: ObservableObject {
    @Published var screens: [Screen] = []
    @Published var activeScreenID: UUID?
    @Published var statByPane: [UUID: SessionStat] = [:]
    @Published var powerMode: PowerManager.Mode = .displayOn { didSet { power.apply(powerMode); persist() } }
    @Published var displays: [DisplayInfo] = []
    @Published var pinnedDisplay: CGDirectDisplayID? { didSet { moveWindow(); persist() } }
    @Published var totalToday: Double = 0
    @Published var focusRequest: UUID?
    @Published var gitLog: [UUID: String] = [:]      // screenID -> last git action output
    @Published var gitBusy: Set<UUID> = []
    @Published var hudInstalled: Bool = HUDManager.isInstalled
    @Published var entitlement: Entitlement = LicenseManager.currentEntitlement()
    @Published var showUpgrade = false
    @Published var upgradeReason = ""

    private let power = PowerManager()
    private var timer: Timer?
    private var controlTimer: Timer?
    private var licenseTimer: Timer?

    private var configDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("fleet")
    }
    private var appConfigURL: URL { configDir.appendingPathComponent("app.json") }
    private var fleetConfigURL: URL { configDir.appendingPathComponent("config.json") }

    var activeScreen: Screen? {
        get { screens.first { $0.id == activeScreenID } }
    }
    func activeScreenIndex() -> Int? { screens.firstIndex { $0.id == activeScreenID } }

    init() {
        load()
        power.apply(powerMode)
        refreshDisplays()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        revalidateLicense()
        licenseTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.revalidateLicense() }
        }
        controlTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processControlFile() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: config / persistence

    private struct AppConfig: Codable {
        var screens: [Screen]?
        var panes: [PaneConfig]?     // legacy single-screen format
        var power: String?
        var displayID: UInt32?
        var activeScreenID: UUID?
    }

    private func homeExpand(_ p: String) -> String {
        p.hasPrefix("~") ? (p as NSString).expandingTildeInPath : p
    }

    func load() {
        if let data = try? Data(contentsOf: appConfigURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            if let s = cfg.screens, !s.isEmpty { screens = s }
            else if let p = cfg.panes, !p.isEmpty { screens = [Screen(name: "main", panes: p)] }
            if let p = cfg.power, let m = PowerManager.Mode(rawValue: p) { powerMode = m }
            if let d = cfg.displayID { pinnedDisplay = d }
            activeScreenID = cfg.activeScreenID
        }
        if screens.isEmpty { screens = [Screen(name: "main", panes: defaultPanesFromFleetConfig())] }
        screens = screens.map { s in
            var s = s
            s.panes = s.panes.map { var q = $0; q.cwd = homeExpand(q.cwd); return q }
            return s
        }
        if activeScreenID == nil || !screens.contains(where: { $0.id == activeScreenID }) {
            activeScreenID = screens.first?.id
        }
    }

    private func defaultPanesFromFleetConfig() -> [PaneConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let data = try? Data(contentsOf: fleetConfigURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let cmd = obj["command"] as? String ?? "claude"
            if let arr = obj["panes"] as? [[String: Any]] {
                return arr.enumerated().map { i, p in
                    PaneConfig(name: p["name"] as? String ?? "pane \(i)",
                               command: p["command"] as? String ?? cmd,
                               cwd: homeExpand(p["cwd"] as? String ?? home))
                }
            }
            if let n = obj["panes"] as? Int {
                return (0..<max(1, n)).map { PaneConfig(name: "pane \($0)", command: cmd, cwd: home) }
            }
        }
        return (0..<2).map { PaneConfig(name: "pane \($0)", command: "claude", cwd: home) }
    }

    func persist() {
        let cfg = AppConfig(screens: screens, panes: nil, power: powerMode.rawValue,
                             displayID: pinnedDisplay, activeScreenID: activeScreenID)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) { try? data.write(to: appConfigURL) }
    }

    // MARK: screens

    /// Adds a new screen. When `repoPath` is set, creates/attaches a git
    /// worktree on `branch` and points every pane's cwd at it — an isolated
    /// checkout so this screen's agents never collide with another screen's.
    @discardableResult
    func addScreen(name: String, repoPath: String?, branch: String?, baseBranch: String,
                   paneCount: Int, command: String) -> Screen? {
        var paneCount = paneCount
        if !entitlement.isEntitled {
            let remaining = freePaneLimit - totalPanes
            if remaining <= 0 {
                requireUpgrade("The free tier runs \(freePaneLimit) panes. Upgrade to add more screens.")
                return nil
            }
            if paneCount > remaining {
                paneCount = remaining
                requireUpgrade("Free tier is capped at \(freePaneLimit) panes — this screen was created with \(remaining).")
            }
        }
        var worktreePath: String?
        var resolvedBranch = branch
        if let repo = repoPath, !repo.isEmpty {
            let br = (branch?.isEmpty == false) ? branch! : name.replacingOccurrences(of: " ", with: "-").lowercased()
            let r = GitWorktree.createOrAttach(repo: repo, branch: br)
            if r.ok { worktreePath = r.output; resolvedBranch = br }
            else { gitLog[UUID()] = "worktree failed: \(r.output)" }
        }
        let cwd = worktreePath ?? repoPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let panes = (0..<max(1, paneCount)).map { PaneConfig(name: "pane \($0)", command: command, cwd: cwd) }
        let screen = Screen(name: name, repoPath: repoPath, worktreePath: worktreePath,
                             branch: resolvedBranch, baseBranch: baseBranch, panes: panes)
        screens.append(screen)
        activeScreenID = screen.id
        persist()
        return screen
    }

    func closeScreen(_ id: UUID, removeWorktree: Bool) {
        guard let s = screens.first(where: { $0.id == id }) else { return }
        if removeWorktree, let repo = s.repoPath, let wt = s.worktreePath {
            _ = GitWorktree.remove(repo: repo, worktree: wt)
        }
        screens.removeAll { $0.id == id }
        if activeScreenID == id { activeScreenID = screens.first?.id }
        if screens.isEmpty { screens = [Screen(name: "main", panes: defaultPanesFromFleetConfig())]; activeScreenID = screens.first?.id }
        persist()
    }

    func renameScreen(_ id: UUID, _ name: String) {
        guard let i = screens.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        screens[i].name = name
        persist()
    }

    func setPaneCount(_ n: Int, in screenID: UUID) {
        guard let i = screens.firstIndex(where: { $0.id == screenID }) else { return }
        var n = max(1, min(16, n))
        if n > screens[i].panes.count, !entitlement.isEntitled {
            let others = totalPanes - screens[i].panes.count
            let allowed = max(1, freePaneLimit - others)
            if n > allowed {
                n = max(allowed, screens[i].panes.count)
                requireUpgrade("The free tier runs \(freePaneLimit) panes. Upgrade for up to 16 per screen.")
            }
        }
        var panes = screens[i].panes
        if n > panes.count {
            let cwd = panes.last?.cwd ?? screens[i].worktreePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            let cmd = panes.last?.command ?? "claude"
            panes += (panes.count..<n).map { PaneConfig(name: "pane \($0)", command: cmd, cwd: cwd) }
        } else if n < panes.count {
            panes.removeLast(panes.count - n)
        }
        screens[i].panes = panes
        persist()
    }

    func rename(pane id: UUID, in screenID: UUID, to name: String) {
        guard let si = screens.firstIndex(where: { $0.id == screenID }),
              let pi = screens[si].panes.firstIndex(where: { $0.id == id }) else { return }
        screens[si].panes[pi].name = name.isEmpty ? screens[si].panes[pi].name : name
        persist()
    }

    func jumpToWaiting() {
        // first look in the active screen, then any other screen (switching to it)
        if let s = activeScreen, let id = s.panes.first(where: { statByPane[$0.id]?.attention == true })?.id {
            focusRequest = id; return
        }
        for s in screens where s.id != activeScreenID {
            if let id = s.panes.first(where: { statByPane[$0.id]?.attention == true })?.id {
                activeScreenID = s.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.focusRequest = id }
                return
            }
        }
    }

    func waitingCount(_ screen: Screen) -> Int {
        screen.panes.filter { statByPane[$0.id]?.attention == true }.count
    }
    func screenCost(_ screen: Screen) -> Double {
        screen.panes.reduce(0) { $0 + (statByPane[$1.id]?.costUsd ?? 0) }
    }
    func screenLastActive(_ screen: Screen) -> Double {
        screen.panes.map { statByPane[$0.id]?.updated ?? 0 }.max() ?? 0
    }

    // MARK: project grouping (sidebar)

    struct ProjectGroup: Identifiable {
        var id: String            // repoPath, or "" for the ungrouped bucket
        var name: String
        var screens: [Screen]
    }

    /// Screens grouped by the repo they're worktree'd from — mirrors how a
    /// Codex/Claude-style sidebar groups conversations under a project.
    /// Non-git screens land in a trailing "No Project" bucket.
    func projectGroups() -> [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [Screen]] = [:]
        for s in screens {
            let key = s.repoPath ?? ""
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]!.append(s)
        }
        // real projects first (by most recent activity), "No Project" last
        let real = order.filter { !$0.isEmpty }
            .sorted { (buckets[$0]!.map(screenLastActive).max() ?? 0) > (buckets[$1]!.map(screenLastActive).max() ?? 0) }
        var groups = real.map { key in
            ProjectGroup(id: key, name: (key as NSString).lastPathComponent, screens: buckets[key]!)
        }
        if let none = buckets[""], !none.isEmpty {
            groups.append(ProjectGroup(id: "", name: "No Project", screens: none))
        }
        return groups
    }

    func recentScreens(limit: Int = 6) -> [Screen] {
        screens.filter { screenLastActive($0) > 0 }
            .sorted { screenLastActive($0) > screenLastActive($1) }
            .prefix(limit)
            .map { $0 }
    }

    /// e.g. "claude" -> "claude", then "claude 2", "claude 3", ... so a quick
    /// spin-up never collides with an existing screen name.
    func nextScreenName(prefix: String) -> String {
        let existing = Set(screens.map { $0.name })
        if !existing.contains(prefix) { return prefix }
        var n = 2
        while existing.contains("\(prefix) \(n)") { n += 1 }
        return "\(prefix) \(n)"
    }

    /// One-click spin-up: a single-pane screen of the given agent, in the
    /// given project (or ungrouped if `repoPath` is nil).
    @discardableResult
    func quickSpin(agent: String, repoPath: String?) -> Screen? {
        addScreen(name: nextScreenName(prefix: agent), repoPath: repoPath, branch: nil,
                  baseBranch: "main", paneCount: 1, command: agent)
    }

    // MARK: licensing

    var freePaneLimit: Int { LicenseManager.product.freePaneLimit }
    var totalPanes: Int { screens.reduce(0) { $0 + $1.panes.count } }

    /// Panes past the free cap (in screen order) stay locked — shown, not spawned —
    /// rather than being deleted, so downgrading never destroys a saved layout.
    func isLocked(_ paneID: UUID) -> Bool {
        if entitlement.isEntitled { return false }
        var n = 0
        for s in screens { for p in s.panes { if p.id == paneID { return n >= freePaneLimit }; n += 1 } }
        return false
    }

    func requireUpgrade(_ reason: String) { flog("upgrade prompt: \(reason)"); upgradeReason = reason; showUpgrade = true }

    func refreshEntitlement() {
        let e = LicenseManager.currentEntitlement()
        if e != entitlement { flog("entitlement: \(entitlement.label) -> \(e.label)"); entitlement = e }
    }

    /// Re-validates any stored license online, then recomputes entitlement.
    func revalidateLicense() {
        Task {
            await LicenseManager.revalidate()
            await MainActor.run { self.refreshEntitlement() }
        }
    }

    func activateLicense(_ key: String) async -> String? {
        let err = await LicenseManager.activate(key: key)
        refreshEntitlement()
        return err
    }

    func deactivateLicense() async -> String? {
        let err = await LicenseManager.deactivate()
        refreshEntitlement()
        return err
    }

    // MARK: control channel
    // ~/.config/fleet/control.json is a one-shot command file: {"cmd": "...", ...}.
    // Lets the CLI (and the hard-test suite, which can't click) drive the app.

    private var controlURL: URL { configDir.appendingPathComponent("control.json") }

    private func processControlFile() {
        guard let data = try? Data(contentsOf: controlURL) else { return }
        try? FileManager.default.removeItem(at: controlURL)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmd = o["cmd"] as? String else { return }
        let name = o["name"] as? String
        let screen = screens.first { $0.name == name }
        flog("control: \(cmd) \(name ?? "")")
        switch cmd {
        case "closeScreen": if let s = screen { closeScreen(s.id, removeWorktree: o["removeWorktree"] as? Bool ?? false) }
        case "select": if let s = screen { activeScreenID = s.id }
        case "activate":
            let key = o["key"] as? String ?? ""
            Task { let r = await self.activateLicense(key); flog("control: activate -> \(r ?? "OK")") }
        case "setPaneCount": if let s = screen, let n = o["count"] as? Int { setPaneCount(n, in: s.id) }
        case "addScreen":
            addScreen(name: name ?? nextScreenName(prefix: "screen"), repoPath: o["repoPath"] as? String,
                      branch: o["branch"] as? String, baseBranch: o["baseBranch"] as? String ?? "main",
                      paneCount: o["panes"] as? Int ?? 1, command: o["command"] as? String ?? "claude")
        default: break
        }
    }

    // MARK: HUD onboarding

    func installHUD() { _ = HUDManager.install(); hudInstalled = HUDManager.isInstalled }
    func uninstallHUD() { _ = HUDManager.uninstall(); hudInstalled = HUDManager.isInstalled }

    // MARK: git sync

    func sync(_ screenID: UUID) {
        guard let s = screens.first(where: { $0.id == screenID }), let wt = s.worktreePath else { return }
        gitBusy.insert(screenID)
        Task.detached { [base = s.baseBranch] in
            let r = GitWorktree.sync(worktree: wt, base: base)
            await MainActor.run {
                self.gitLog[screenID] = r.ok ? "synced with \(base)" : r.output
                self.gitBusy.remove(screenID)
            }
        }
    }

    func push(_ screenID: UUID) {
        guard let s = screens.first(where: { $0.id == screenID }), let wt = s.worktreePath, let br = s.branch else { return }
        gitBusy.insert(screenID)
        Task.detached {
            let r = GitWorktree.push(worktree: wt, branch: br)
            await MainActor.run {
                self.gitLog[screenID] = r.ok ? "pushed \(br)" : r.output
                self.gitBusy.remove(screenID)
            }
        }
    }

    // MARK: polling
    // One directory scan per cycle (not one per pane — see SessionStats.all's
    // doc comment; that was an O(panes × sidecar-files) bug at real scale),
    // done off the main actor since a large sessions/ folder means real I/O.

    private var pollCount = 0

    private func poll() {
        let paneCwds: [(UUID, String)] = screens.flatMap { s in s.panes.map { ($0.id, $0.cwd) } }
        pollCount += 1
        refreshEntitlement()
        let prune = pollCount % 100 == 0   // roughly every ~5 minutes at a 3s interval
        Task.detached(priority: .utility) {
            let stats = SessionStats.all()
            var map: [UUID: SessionStat] = [:]
            for (id, cwd) in paneCwds { if let s = SessionStats.match(stats, path: cwd) { map[id] = s } }
            let total = SessionStats.totalCostToday(stats)
            if prune { SessionStats.pruneOlderThan(days: 30) }
            await MainActor.run {
                self.statByPane = map
                self.totalToday = total
            }
        }
    }

    // MARK: displays

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            return DisplayInfo(id: id, name: screen.localizedName, isMain: CGDisplayIsMain(id) != 0)
        }
    }

    @objc private func screensParamsChanged() {
        refreshDisplays()
        if let pinned = pinnedDisplay, !displays.contains(where: { $0.id == pinned }) {
            pinnedDisplay = displays.first(where: { $0.isMain })?.id ?? displays.first?.id
        } else {
            moveWindow()
        }
    }

    func moveWindow() {
        guard let pinned = pinnedDisplay,
              let window = NSApp.windows.first(where: { $0.isVisible }),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == pinned
              })
        else { return }
        let vis = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }
}
