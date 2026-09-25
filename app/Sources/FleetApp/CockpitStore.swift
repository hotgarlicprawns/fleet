import SwiftUI
import AppKit

/// One Claude Code or Codex login. Each extra account is just its own
/// config directory: Claude Code keys its login (Keychain entry, settings,
/// history) by CLAUDE_CONFIG_DIR, and Codex by CODEX_HOME — the officially
/// supported way to run several subscriptions side by side. "No account"
/// (accountID == nil) means your normal ~/.claude / ~/.codex login.
struct Account: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable { case claude, codex }
    var id = UUID()
    var name: String
    var kind: Kind
    var configDir: String

    /// The env vars a pane on this account launches with.
    var environment: [String] {
        [(kind == .claude ? "CLAUDE_CONFIG_DIR=" : "CODEX_HOME=") + configDir, "FLEET_ACCOUNT=\(name)"]
    }
}

struct PaneConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var cwd: String
    /// Whether this pane's name may still be auto-updated from the
    /// terminal's own title (Claude Code sets one via the standard xterm
    /// OSC title escape once real work starts). A manual rename turns this
    /// off permanently for that pane — auto-naming never fights a name you
    /// chose yourself.
    var autoNamed: Bool = true
    /// nil = the default login. Changing it restarts the pane (a running
    /// process can't switch accounts), see PaneCell's `.id`.
    var accountID: UUID? = nil

    /// Codex panes take Codex accounts; everything else is treated as Claude Code.
    var agentKind: Account.Kind { command.trimmingCharacters(in: .whitespaces).hasPrefix("codex") ? .codex : .claude }

    enum CodingKeys: String, CodingKey { case id, name, command, cwd, autoNamed, accountID }

    init(name: String, command: String, cwd: String, accountID: UUID? = nil) {
        self.name = name; self.command = command; self.cwd = cwd; self.accountID = accountID
        // A default-shaped name ("pane 0", "claude 2", …) is still fair
        // game for auto-naming; anything else was presumably already
        // chosen deliberately (e.g. a saved config from before this
        // existed) and shouldn't be overwritten out from under someone.
        self.autoNamed = PaneConfig.looksDefaultNamed(name)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = (try? c.decode(String.self, forKey: .command)) ?? "claude"
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? FileManager.default.homeDirectoryForCurrentUser.path
        autoNamed = (try? c.decode(Bool.self, forKey: .autoNamed)) ?? PaneConfig.looksDefaultNamed(name)
        accountID = try? c.decode(UUID.self, forKey: .accountID)
    }

    static func looksDefaultNamed(_ name: String) -> Bool {
        name.range(of: #"^(pane|claude|codex) \d+$"#, options: .regularExpression) != nil
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
    @Published var accounts: [Account] = []
    @Published var activeScreenID: UUID? {
        // Defensive fallback: if something ever assigns an id that isn't in
        // `screens`, fall back instead of leaving every ScreenGrid hidden and
        // non-interactive at once (see the ZStack in CockpitView — visibility
        // and hit-testing both key off `screen.id == activeScreenID`, so an
        // unmatched id makes every screen invisible AND unclickable
        // simultaneously, which looks exactly like a dead, unwritable app).
        // `load()` and `closeScreen` already guard the known paths that could
        // produce this; this is a last-resort net for any path that doesn't.
        didSet {
            if let id = activeScreenID, !screens.contains(where: { $0.id == id }) {
                activeScreenID = screens.first?.id
            }
        }
    }
    @Published var statByPane: [UUID: SessionStat] = [:]
    @Published var powerMode: PowerManager.Mode = .displayOn { didSet { power.apply(powerMode); persist() } }
    @Published var displays: [DisplayInfo] = []
    @Published var pinnedDisplay: CGDirectDisplayID? { didSet { moveWindow(); persist() } }
    @Published var totalToday: Double = 0
    @Published var rateByAccount: [String: SessionStats.RateReading] = [:]
    @Published var leanLive: (calls: Int, tokens: Int) = (0, 0)
    @Published var leanAllTime: (calls: Int, tokens: Int, days: Int)?
    @Published var focusRequest: UUID?
    /// Which pane actually has keyboard focus right now, per AppKit's real
    /// first responder — not assumed, not "whichever pane is last". Backs
    /// ⌘⇧W ("Remove Last Pane" used to always mean literally last, which
    /// was the actual bug behind it "removing the wrong pane"). Updated
    /// from paneViews on the 1s controlTimer tick (see checkFocusedPane()).
    @Published private(set) var focusedPaneID: UUID?
    /// Weak-by-construction: entries are added in TerminalPane.makeNSView
    /// and removed in dismantleNSView, so this never outlives the pane.
    var paneViews: [UUID: NSView] = [:]
    /// screen id -> the pane maximized within it, if any. Transient (not
    /// persisted) — a fresh launch always starts with the normal grid.
    @Published var maximizedPane: [UUID: UUID] = [:]
    @Published var gitLog: [UUID: String] = [:]      // screenID -> last git action output
    @Published var gitBusy: Set<UUID> = []
    @Published var hudInstalled: Bool = HUDManager.isInstalled
    @Published var entitlement: Entitlement = LicenseManager.currentEntitlement()
    @Published var notice: String? = nil
    @Published var showUpgrade = false
    @Published var showReport = false
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
        if HUDManager.upgradeIfStale() { flog("HUD script upgraded to the bundled version") }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        revalidateLicense()
        licenseTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.revalidateLicense() }
        }
        controlTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processControlFile(); self?.checkFocusedPane() }
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
        var accounts: [Account]?
    }

    private func homeExpand(_ p: String) -> String {
        p.hasPrefix("~") ? (p as NSString).expandingTildeInPath : p
    }

    func load() {
        var hadExplicitScreensKey = false
        if let data = try? Data(contentsOf: appConfigURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            if let s = cfg.screens { screens = s; hadExplicitScreensKey = true }
            else if let p = cfg.panes, !p.isEmpty { screens = [Screen(name: "main", panes: p)] }
            if let p = cfg.power, let m = PowerManager.Mode(rawValue: p) { powerMode = m }
            if let d = cfg.displayID { pinnedDisplay = d }
            activeScreenID = cfg.activeScreenID
            accounts = cfg.accounts ?? []
        }
        // Only seed a default screen when there was truly nothing configured
        // — no app.json at all, or one with neither `screens` nor `panes` —
        // never when the saved config explicitly says `screens: []`, which
        // means the user deliberately closed every screen. The previous
        // version treated those the same, so closing your last screen never
        // actually stuck: reopening Fleet (or this same load() running
        // again) silently recreated a fresh "main" screen every time.
        if screens.isEmpty && !hadExplicitScreensKey {
            screens = [Screen(name: "main", panes: defaultPanesFromFleetConfig())]
        }
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
                             displayID: pinnedDisplay, activeScreenID: activeScreenID, accounts: accounts)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) { try? data.write(to: appConfigURL) }
    }

    // MARK: screens

    /// Adds a new screen. When `repoPath` is set, creates/attaches a git
    /// worktree on `branch` and points every pane's cwd at it — an isolated
    /// checkout so this screen's agents never collide with another screen's.
    @discardableResult
    func addScreen(name: String, repoPath: String?, branch: String?, baseBranch: String,
                   paneCount: Int, command: String, accountID: UUID? = nil) -> Screen? {
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
        let panes = (0..<max(1, paneCount)).map { PaneConfig(name: "pane \($0)", command: command, cwd: cwd, accountID: accountID) }
        let screen = Screen(name: name, repoPath: repoPath, worktreePath: worktreePath,
                             branch: resolvedBranch, baseBranch: baseBranch, panes: panes)
        screens.append(screen)
        select(screen.id) // also moves focus into the new screen's first pane, and persists
        return screen
    }

    func closeScreen(_ id: UUID, removeWorktree: Bool) {
        guard let s = screens.first(where: { $0.id == id }) else { return }
        screens.removeAll { $0.id == id }
        if activeScreenID == id { activeScreenID = screens.first?.id }
        // Closing down to zero screens is now a legitimate end state — the
        // real empty-state view in CockpitView handles it. This used to
        // immediately recreate a fresh default screen, which is why closing
        // your last screen never actually stuck (you'd always land back on a
        // new "main" screen instead of the empty state).
        persist()
        guard removeWorktree, let repo = s.repoPath, let wt = s.worktreePath else { return }
        // Removing the screen tears its terminals down (agents get SIGTERM, then
        // SIGKILL after 2s). Wait for that before touching the directory they ran in.
        let branch = s.branch
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            let r = GitWorktree.remove(repo: repo, worktree: wt, deleteBranch: branch)
            await MainActor.run { self.notify("\(s.name): \(r.output)") }
        }
    }

    /// A transient message shown at the bottom of the window.
    func notify(_ text: String) {
        flog("notice: \(text)")
        notice = text
        let mine = text
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if self.notice == mine { self.notice = nil } }
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
            // The screen's own baseline, from its FIRST pane — not its last.
            // A screen's later panes can end up with an unusual one-off
            // command (a test fixture, a manual override); using `.last`
            // meant that command would keep spreading to every pane added
            // after it, rather than the screen's actual intended agent.
            let cwd = panes.first?.cwd ?? screens[i].worktreePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            let cmd = panes.first?.command ?? "claude"
            let acct = panes.first?.accountID
            panes += (panes.count..<n).map { PaneConfig(name: "pane \($0)", command: cmd, cwd: cwd, accountID: acct) }
        } else if n < panes.count {
            let removed = panes.suffix(panes.count - n)
            panes.removeLast(panes.count - n)
            for p in removed {
                statByPane[p.id] = nil
                if maximizedPane[screenID] == p.id { maximizedPane[screenID] = nil }
            }
        }
        screens[i].panes = panes
        persist()
    }

    /// Removes exactly the pane the caller specifies, killing its agent —
    /// unlike setPaneCount/MiniStepper, which only ever removed whichever
    /// pane happened to be LAST, not the one you were looking at. That was
    /// the actual bug behind "the minus button doesn't work": it worked, it
    /// just never closed the pane you wanted. A screen may end up with zero
    /// panes; ScreenGrid shows an "+ add pane" empty state for that screen.
    /// Closes whichever pane has real keyboard focus (falls back to the
    /// screen's last pane if nothing is focused yet). Shared by the
    /// ⌘⇧W menu command and the test control file, so both exercise the
    /// exact same code path.
    func closeFocusedPane(in screenID: UUID) {
        guard let s = screens.first(where: { $0.id == screenID }) else { return }
        let target = s.panes.first(where: { $0.id == focusedPaneID }) ?? s.panes.last
        if let target { closePane(target.id, in: screenID) }
    }

    func closePane(_ id: UUID, in screenID: UUID) {
        guard let i = screens.firstIndex(where: { $0.id == screenID }) else { return }
        screens[i].panes.removeAll { $0.id == id }
        if maximizedPane[screenID] == id { maximizedPane[screenID] = nil }
        statByPane[id] = nil
        if focusedPaneID == id { focusedPaneID = nil } // don't wait for the next poll tick
        persist()
    }

    func rename(pane id: UUID, in screenID: UUID, to name: String) {
        guard let si = screens.firstIndex(where: { $0.id == screenID }),
              let pi = screens[si].panes.firstIndex(where: { $0.id == id }) else { return }
        screens[si].panes[pi].name = name.isEmpty ? screens[si].panes[pi].name : name
        screens[si].panes[pi].autoNamed = false // a manual rename always wins from here on
        persist()
    }

    /// Cleans a raw terminal-title string (spinner glyphs, braille frames,
    /// generic "claude"/"codex" chrome) and applies it as the pane's name —
    /// but only if this pane hasn't been manually renamed, and only if the
    /// cleaned result actually differs from its current name (title updates
    /// fire on nearly every render; comparing after cleaning avoids
    /// thrashing persist() on every spinner frame).
    func autoName(pane id: UUID, in screenID: UUID, title: String) {
        guard let si = screens.firstIndex(where: { $0.id == screenID }),
              let pi = screens[si].panes.firstIndex(where: { $0.id == id }),
              screens[si].panes[pi].autoNamed
        else { return }
        guard let cleaned = Self.cleanTerminalTitle(title), cleaned != screens[si].panes[pi].name else { return }
        screens[si].panes[pi].name = cleaned
        persist()
    }

    static func cleanTerminalTitle(_ raw: String) -> String? {
        // Strip leading spinner glyphs (✳ ✻ · and the braille block used by
        // several CLI spinners, U+2800–28FF) and surrounding whitespace.
        var s = raw
        while let f = s.unicodeScalars.first,
              CharacterSet(charactersIn: "✳✻·-").contains(f) || (0x2800...0x28FF).contains(Int(f.value)) {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 3 else { return nil }
        let lower = s.lowercased()
        if ["claude", "claude code", "codex"].contains(lower) { return nil }
        // Looks like a bare path or a user@host prompt string, not a real title.
        if s.hasPrefix("/") || s.hasPrefix("~") || s.contains("@") { return nil }
        if s.count > 28 { s = String(s.prefix(27)) + "…" }
        return s
    }

    /// Switches the active screen AND moves keyboard focus into it — the one
    /// path every screen switch should go through. A plain `activeScreenID =`
    /// assignment (the previous pattern, used at several call sites) changes
    /// which ScreenGrid is visible/hit-testable but never moves AppKit's
    /// first responder away from the previous screen's terminal, which stays
    /// mounted at opacity 0 (not torn down, so its agent keeps running).
    /// Keystrokes kept going to that now-invisible terminal — the screen you
    /// were looking at took no input at all, which reads exactly like a dead,
    /// unwritable app. Also persists the selection immediately; a plain
    /// assignment was never saved, so relaunching Fleet could restore an old
    /// screen instead of the one you'd switched to.
    func select(_ screenID: UUID) {
        guard let s = screens.first(where: { $0.id == screenID }) else { return }
        activeScreenID = screenID
        persist()
        focusRequest = s.panes.first(where: { !isLocked($0.id) })?.id
    }

    /// Reads AppKit's ACTUAL first responder (real state, not a guess) and
    /// maps it back to whichever registered pane view contains it —
    /// `firstResponder` for a terminal is a subview (SwiftTerm's inner text
    /// view), so containment (`isDescendant(of:)`), not identity, is the
    /// right test. A window with no matching responder (nothing focused
    /// yet, or focus in a non-pane control) clears it rather than keeping a
    /// stale pane "current" forever.
    func checkFocusedPane() {
        // NSApp.keyWindow is nil whenever Fleet isn't the OS-level frontmost
        // app (true for a headless test run, and possible any time the user
        // has another app focused) — but the fleet window's OWN first
        // responder is still tracked internally by AppKit regardless, so
        // look the window up by title (same pattern as Hotkey.summon,
        // moveWindow, and the "performClose"/"windowState" control commands
        // elsewhere in this file) instead of going through keyWindow.
        guard let window = NSApp.windows.first(where: { $0.title == "fleet" }),
              let responder = window.firstResponder as? NSView else { focusedPaneID = nil; return }
        focusedPaneID = paneViews.first(where: { responder.isDescendant(of: $0.value) })?.key
    }

    func jumpToWaiting() {
        // first look in the active screen, then any other screen (switching to it)
        if let s = activeScreen, let id = s.panes.first(where: { statByPane[$0.id]?.attention == true })?.id {
            focusRequest = id; return
        }
        for s in screens where s.id != activeScreenID {
            if let id = s.panes.first(where: { statByPane[$0.id]?.attention == true })?.id {
                activeScreenID = s.id
                persist() // switching screens must always persist — see select()'s doc comment
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
        case "closePane":
            if let s = screen, let paneName = o["pane"] as? String,
               let p = s.panes.first(where: { $0.name == paneName }) { closePane(p.id, in: s.id) }
        case "select": if let s = screen { select(s.id) }
        case "focusPane":
            // Test hook for real first-responder-based focus tracking: sets
            // focusRequest directly (bypassing select(), which always picks
            // the first pane) so a specific non-first pane gets a REAL
            // makeFirstResponder call — see TerminalPane.updateNSView.
            if let s = screen, let paneName = o["pane"] as? String,
               let p = s.panes.first(where: { $0.name == paneName }) { focusRequest = p.id }
        case "closeFocused": if let s = screen { closeFocusedPane(in: s.id) }
        case "performClose": NSApp.windows.first(where: { $0.title == "fleet" })?.performClose(nil)
        case "summon": Hotkey.summon()
        case "showUpgrade": upgradeReason = o["reason"] as? String ?? ""; showUpgrade = true
        case "showReport": showReport = true
        case "dumpState":
            // Internal test hook — writes the toolbar rollups to a file the
            // hard-test suite can read, since there's no UI automation for
            // them (the "8. UI automation" section needs Accessibility
            // permission and is usually skipped in CI).
            let rates = rateByAccount.mapValues { ["rl5h": $0.rl5h as Any, "rl7d": $0.rl7d as Any] }
            let obj: [String: Any] = [
                "rateByAccount": rates,
                "leanLiveCalls": leanLive.calls, "leanLiveTokens": leanLive.tokens,
                "leanAllTimeCalls": leanAllTime?.calls ?? 0, "leanAllTimeTokens": leanAllTime?.tokens ?? 0,
                "accounts": accounts.map { ["name": $0.name, "kind": $0.kind.rawValue, "configDir": $0.configDir] },
                "focusedPaneName": screens.flatMap { $0.panes }.first { $0.id == focusedPaneID }?.name as Any
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                try? data.write(to: configDir.appendingPathComponent("state-dump.json"))
            }
        case "windowState":
            let w = NSApp.windows.first(where: { $0.title == "fleet" })
            flog("windowState: visible=\(w?.isVisible ?? false) id=\(w?.windowNumber ?? 0) app=running all=\(NSApp.windows.map { "\($0.title.isEmpty ? "-" : $0.title):\($0.isVisible ? "v" : "h"):\(type(of: $0))" })")
        case "activate":
            let key = o["key"] as? String ?? ""
            Task { let r = await self.activateLicense(key); flog("control: activate -> \(r ?? "OK")") }
        case "setPaneCount": if let s = screen, let n = o["count"] as? Int { setPaneCount(n, in: s.id) }
        case "addAccount":
            if let n = o["account"] as? String { addAccount(name: n, kind: Account.Kind(rawValue: o["kind"] as? String ?? "claude") ?? .claude) }
        case "setAccount":
            // pane on screen `name` -> account named `account` (or default when absent)
            if let s = screen, let paneName = o["pane"] as? String,
               let p = s.panes.first(where: { $0.name == paneName }) {
                setAccount(pane: p.id, in: s.id, to: accounts.first { $0.name == (o["account"] as? String) }?.id)
            }
        case "addScreen":
            addScreen(name: name ?? nextScreenName(prefix: "screen"), repoPath: o["repoPath"] as? String,
                      branch: o["branch"] as? String, baseBranch: o["baseBranch"] as? String ?? "main",
                      paneCount: o["panes"] as? Int ?? 1, command: o["command"] as? String ?? "claude")
        default: break
        }
    }

    // MARK: accounts

    func account(_ id: UUID?) -> Account? { id.flatMap { i in accounts.first { $0.id == i } } }

    /// Creates a new account with its own config dir under
    /// ~/.config/fleet/accounts/. Seeds it from the default login's
    /// settings so it behaves like your normal setup — same settings.json
    /// (permissions, enabled plugins, and the fleet HUD statusLine if you
    /// use it), and the same installed plugins (symlinked, so fleet-lean and
    /// friends work without reinstalling). Never copies credentials: each
    /// account signs in on its own.
    @discardableResult
    func addAccount(name: String, kind: Account.Kind) -> Account? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !accounts.contains(where: { $0.name == clean && $0.kind == kind }) else { return nil }
        let slug = clean.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        let dir = configDir.appendingPathComponent("accounts/\(kind.rawValue)-\(slug)-\(UUID().uuidString.prefix(6).lowercased())")
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { notify("couldn't create account folder: \(error.localizedDescription)"); return nil }
        let home = fm.homeDirectoryForCurrentUser
        if kind == .claude {
            let src = home.appendingPathComponent(".claude")
            try? fm.copyItem(at: src.appendingPathComponent("settings.json"), to: dir.appendingPathComponent("settings.json"))
            for shared in ["plugins", "CLAUDE.md", "agents", "commands", "skills"] {
                let from = src.appendingPathComponent(shared)
                if fm.fileExists(atPath: from.path) {
                    try? fm.createSymbolicLink(at: dir.appendingPathComponent(shared), withDestinationURL: from)
                }
            }
        } else {
            try? fm.copyItem(at: home.appendingPathComponent(".codex/config.toml"), to: dir.appendingPathComponent("config.toml"))
        }
        let a = Account(name: clean, kind: kind, configDir: dir.path)
        accounts.append(a)
        if kind == .claude && hudInstalled { HUDManager.install(claudeConfigDir: dir) }
        persist()
        return a
    }

    /// Forgets an account. Panes on it fall back to the default login (and
    /// restart). The folder is left on disk — it holds that account's
    /// history, and deleting someone's data isn't a side effect of a
    /// settings click.
    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        for si in screens.indices {
            for pi in screens[si].panes.indices where screens[si].panes[pi].accountID == id {
                screens[si].panes[pi].accountID = nil
            }
        }
        persist()
    }

    func setAccount(pane id: UUID, in screenID: UUID, to accountID: UUID?) {
        guard let si = screens.firstIndex(where: { $0.id == screenID }),
              let pi = screens[si].panes.firstIndex(where: { $0.id == id }),
              screens[si].panes[pi].accountID != accountID else { return }
        screens[si].panes[pi].accountID = accountID
        statByPane[id] = nil // the old account's cost/context no longer applies
        persist()
    }

    /// Opens a pane on `account` that walks through its login: a fresh
    /// CLAUDE_CONFIG_DIR makes `claude` start its own sign-in flow; Codex
    /// has an explicit `codex login`.
    func openSignIn(_ account: Account) {
        if !entitlement.isEntitled && totalPanes >= freePaneLimit {
            requireUpgrade("The free tier runs \(freePaneLimit) panes. Close one to sign in, or upgrade.")
            return
        }
        let pane = PaneConfig(name: "sign in · \(account.name)",
                              command: account.kind == .claude ? "claude" : "codex login",
                              cwd: FileManager.default.homeDirectoryForCurrentUser.path, accountID: account.id)
        if let i = activeScreenIndex() {
            screens[i].panes.append(pane)
            select(screens[i].id)
            focusRequest = pane.id
        } else {
            let s = Screen(name: "accounts", panes: [pane])
            screens.append(s)
            select(s.id)
        }
        persist()
    }

    // MARK: HUD onboarding

    func installHUD() {
        _ = HUDManager.install()
        for a in accounts where a.kind == .claude { HUDManager.install(claudeConfigDir: URL(fileURLWithPath: a.configDir)) }
        hudInstalled = HUDManager.isInstalled
    }
    func uninstallHUD() {
        _ = HUDManager.uninstall()
        for a in accounts where a.kind == .claude { HUDManager.uninstall(claudeConfigDir: URL(fileURLWithPath: a.configDir)) }
        hudInstalled = HUDManager.isInstalled
    }

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
        let paneIDs: [UUID] = screens.flatMap { s in s.panes.map { $0.id } }
        pollCount += 1
        refreshEntitlement()
        let prune = pollCount % 100 == 0   // roughly every ~5 minutes at a 3s interval
        Task.detached(priority: .utility) {
            // one scan covers both needs: 24h for the spend total, and the last
            // 8h (live-ish sessions) for matching panes so stale costs don't stick.
            let day = SessionStats.load(maxAgeHours: 24)
            let cutoff = Date().timeIntervalSince1970 - 8 * 3600
            let recent = day.filter { ($0.updated ?? 0) > cutoff }
            var map: [UUID: SessionStat] = [:]
            for id in paneIDs { if let s = SessionStats.match(recent, paneID: id) { map[id] = s } }
            let total = SessionStats.totalCostToday(day)
            let rates = SessionStats.rateByAccount(recent)
            let claudePids = Set(map.values.compactMap { $0.claudePid })
            let live = LeanSavings.liveTotals(claudePids: claudePids)
            let allTime = LeanSavings.allTimeTotals()
            if prune { SessionStats.pruneOlderThan(days: 30) }
            await MainActor.run {
                self.statByPane = map
                self.totalToday = total
                self.rateByAccount = rates
                self.leanLive = live
                self.leanAllTime = allTime
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
        // Match by title, not just "any visible window" — now that a
        // Settings window exists, changing the display pin FROM Settings
        // would otherwise move the Settings window instead of the main one.
        guard let pinned = pinnedDisplay,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "fleet" }),
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
