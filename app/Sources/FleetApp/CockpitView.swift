import SwiftUI
import AppKit

/// Shared by PaneCell's per-pane rate chips and the toolbar's account-level
/// rate chips (see the top-bar redesign) — one definition, used both places.
func fleetRateColor(_ p: Int) -> Color { p >= 90 ? Theme.red : p >= 70 ? Theme.amber : Theme.inkFaint }
/// "1.2k" for 1234 — matches the same rounding/labeling convention
/// plugin-lean/report.js's fmt() uses for its own token counts.
func fleetCompact(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n)
}

struct CockpitView: View {
    @EnvironmentObject var store: CockpitStore
    @State private var showingNewScreen = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(showingNewScreen: $showingNewScreen)
                .frame(width: 264)
                .background(Theme.panel)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Theme.line).frame(height: 1)
                planBanner
                if !store.hudInstalled { hudOnboardingBanner }
                ZStack {
                    ForEach(store.screens) { screen in
                        ScreenGrid(screen: screen)
                            .opacity(screen.id == store.activeScreenID ? 1 : 0)
                            .allowsHitTesting(screen.id == store.activeScreenID)
                            .zIndex(screen.id == store.activeScreenID ? 1 : 0)
                    }
                    if store.screens.isEmpty {
                        EmptyScreensCTA(showingNewScreen: $showingNewScreen)
                    }
                }
            }
        }
        .background(Theme.ground)
        .overlay(alignment: .bottom) {
            if let n = store.notice {
                Text(n).font(Theme.mono(11.5)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lineStrong, lineWidth: 1))
                    .padding(.bottom, 18).transition(.opacity)
            }
        }
        .sheet(isPresented: $showingNewScreen) { NewScreenSheet(isPresented: $showingNewScreen) }
        .sheet(isPresented: $store.showUpgrade) { UpgradeSheet() }
        .sheet(isPresented: $store.showReport) { ReportSheet() }
        .task {
            // Nothing sets keyboard focus at launch otherwise — TerminalPane
            // only calls makeFirstResponder when focusRequest matches its own
            // pane id, and nothing did that on startup. The active screen
            // rendered correctly but silently took no keystrokes at all,
            // which reads exactly like a dead app. The short delay gives
            // AppDelegate.ensureWindow time to actually make the window key
            // first (makeFirstResponder is a no-op on a window that isn't).
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let id = store.activeScreenID { store.select(id) }
        }
    }

    @ViewBuilder private var planBanner: some View {
        switch store.entitlement {
        case .free:
            planBar("Free tier — \(store.freePaneLimit) panes. Your trial has ended.", "Upgrade")
        case .trial(let d) where d <= 5:
            planBar("Trial ends in \(d) day\(d == 1 ? "" : "s") — after that Fleet runs \(store.freePaneLimit) panes.", "Keep Pro")
        default:
            EmptyView()
        }
    }
    private func planBar(_ text: String, _ cta: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.amber).frame(width: 6, height: 6)
            Text(text).font(Theme.mono(11.5)).foregroundStyle(Theme.inkSoft)
            Spacer()
            FleetButton(title: cta, primary: true) { store.upgradeReason = ""; store.showUpgrade = true }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.panel2)
    }

    private var hudOnboardingBanner: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text("Cost, context and rate-limit tracking is off.")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.inkSoft)
            Text("One click — wires into Claude Code, keeps your current status line.")
                .font(Theme.mono(11)).foregroundStyle(Theme.inkFaint)
            Spacer()
            FleetButton(title: "Turn on HUD", primary: true) { store.installHUD() }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.panel2)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if let s = store.activeScreen {
                Circle().fill(store.waitingCount(s) > 0 ? Theme.accent : Theme.inkFaint.opacity(0.5)).frame(width: 6, height: 6)
                // screen name truncates first when space is tight — least costly to lose
                Text(s.name).font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
                if s.isGitBacked { gitMenu(s) }
                // A stepper here doubled up with per-pane × buttons in each
                // header (its minus always removed whichever pane happened
                // to be LAST, not one you chose) and crowded the toolbar.
                // "+ pane" only adds; removing a specific pane is now that
                // pane's own × button.
                Button { store.setPaneCount(s.panes.count + 1, in: s.id) } label: {
                    Image(systemName: "plus.square").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
                .help("Add a pane (⌘T)")
            } else {
                Text("fleet").font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.inkFaint).fixedSize()
            }

            Spacer(minLength: 8)

            // Rate limits used to repeat identically on every pane of the
            // same account (they're account-wide, not per-session), and a
            // brand-new pane with no reading yet just looked like it
            // disagreed with the others. One chip per account here instead —
            // today that's just "default" until multi-account support
            // exists, but the grouping is already account-aware.
            ForEach(store.rateByAccount.sorted(by: { $0.key < $1.key }), id: \.key) { key, r in
                HStack(spacing: 6) {
                    if key != "default" { Text(key).font(Theme.mono(10, .medium)).foregroundStyle(Theme.inkSoft) }
                    if let rl5 = r.rl5h { Text("5h \(rl5)%").foregroundStyle(fleetRateColor(rl5)) }
                    if let rl7 = r.rl7d { Text("7d \(rl7)%").foregroundStyle(fleetRateColor(rl7)) }
                }
                .font(Theme.mono(11)).lineLimit(1).fixedSize()
                .help("Claude Code rate limits for this account")
            }

            // Real, code-computed fleet-lean savings (plugin-lean/report.js's
            // same numbers) — never a fabricated figure. Hidden entirely if
            // fleet-lean has never run, rather than showing "0 saved".
            if let all = store.leanAllTime, all.calls > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 10))
                    if store.leanLive.calls > 0 {
                        Text("↓\(fleetCompact(store.leanLive.tokens)) tok live")
                    } else {
                        Text("↓\(fleetCompact(all.tokens)) tok all-time")
                    }
                }
                .font(Theme.mono(11)).foregroundStyle(Theme.accentInk).lineLimit(1).fixedSize()
                .help("fleet-lean: \(all.calls) built-in calls avoided all-time (exact), ~\(all.tokens) tokens avoided (est.) — see /fleet-lean-report")
            }

            let totalWaiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
            if totalWaiting > 0 {
                FleetButton(title: "\(totalWaiting) waiting", systemImage: "bell.badge.fill", primary: true) { store.jumpToWaiting() }
            }
            Text(String(format: "$%.2f", store.totalToday))
                .font(Theme.mono(12)).foregroundStyle(Theme.inkFaint).lineLimit(1).fixedSize()
                .help("Total Claude Code spend in the last 24h")

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
                .help("Settings — power mode, display, HUD, license")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.panel)
    }

    /// Sync / Push / last-result folded into one menu so the toolbar stays
    /// a single fixed-height row no matter the branch name length.
    private func gitMenu(_ s: Screen) -> some View {
        Menu {
            Button("Sync onto \(s.baseBranch)") { store.sync(s.id) }.disabled(store.gitBusy.contains(s.id))
            Button("Push \(s.branch ?? "")") { store.push(s.id) }.disabled(store.gitBusy.contains(s.id))
            if let log = store.gitLog[s.id] { Divider(); Text(log) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(s.branch ?? "?").font(Theme.mono(11)).lineLimit(1)
                if store.gitBusy.contains(s.id) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(Theme.inkFaint)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.lineStrong, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var store: CockpitStore
    @Binding var showingNewScreen: Bool
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 22) // clears the traffic lights (hiddenTitleBar)

            HStack(spacing: 8) {
                Text("fleet").font(Theme.mono(15, .bold)).foregroundStyle(Theme.ink)
                Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -5)
                Spacer()
                let waiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
                Button { store.jumpToWaiting() } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell").font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                        if waiting > 0 { Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 2, y: -1) }
                    }
                }.buttonStyle(.plain).disabled(waiting == 0)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)

            SidebarRow(icon: "plus.circle.fill", label: "New Screen", iconColor: Theme.accent) { showingNewScreen = true }
                .padding(.horizontal, 8)
            SidebarRow(icon: "chart.bar", label: "Spend report") { store.showReport = true }
                .padding(.horizontal, 8)

            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let recents = store.recentScreens()
                    if !recents.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            sectionLabel("Recents")
                            ForEach(recents) { s in ScreenRow(screen: s, showProject: true) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("Projects")
                        ForEach(store.projectGroups()) { group in
                            ProjectSection(group: group, collapsed: collapsed.contains(group.id)) {
                                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                            }
                            if !collapsed.contains(group.id) {
                                ForEach(group.screens) { s in ScreenRow(screen: s, showProject: false) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 20)
            }

            Spacer(minLength: 0)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Button { store.upgradeReason = ""; store.showUpgrade = true } label: {
                    HStack(spacing: 6) {
                        Circle().fill(store.entitlement == .pro ? Theme.accent : Theme.amber).frame(width: 7, height: 7)
                        Text(store.entitlement.label).font(Theme.mono(11, .medium)).foregroundStyle(Theme.inkSoft)
                    }
                }.buttonStyle(.plain)
                    .help(store.entitlement == .pro ? "License" : "Upgrade or activate a license")
                Spacer()
                Text(String(format: "$%.2f", store.totalToday)).font(Theme.mono(11)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(Theme.mono(10, .semibold))
            .foregroundStyle(Theme.inkFaint)
            .kerning(1.2)
            .padding(.horizontal, 8)
    }
}

private struct SidebarRow: View {
    let icon: String; let label: String; var iconColor: Color = Theme.inkSoft
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(iconColor).frame(width: 16)
                Text(label).font(Theme.mono(12.5, .medium)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hover ? Theme.panel2 : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A project header — expandable, with one-click "spin up a claude/codex
/// screen in this project" buttons that appear on hover.
private struct ProjectSection: View {
    @EnvironmentObject var store: CockpitStore
    let group: CockpitStore.ProjectGroup
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8)).foregroundStyle(Theme.inkFaint).frame(width: 10)
            Image(systemName: group.id.isEmpty ? "tray" : "folder.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
            Text(group.name).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.inkSoft).lineLimit(1)
            Spacer()
            if hover {
                spinButton(agent: "claude", tint: Theme.accent, glyph: "C")
                spinButton(agent: "codex", tint: Theme.codex, glyph: "X")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
    }

    private func spinButton(agent: String, tint: Color, glyph: String) -> some View {
        Button {
            store.quickSpin(agent: agent, repoPath: group.id.isEmpty ? nil : group.id)
        } label: {
            Text(glyph).font(Theme.mono(9, .bold))
                .frame(width: 16, height: 16)
                .background(tint.opacity(0.18)).foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Spin up a new \(agent) screen in \(group.name)")
    }
}

private struct ScreenRow: View {
    @EnvironmentObject var store: CockpitStore
    let screen: Screen
    let showProject: Bool
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""

    private func confirmClose() {
        guard screen.isGitBacked else { store.closeScreen(screen.id, removeWorktree: false); return }
        let a = NSAlert()
        a.messageText = "Close “\(screen.name)”?"
        a.informativeText = "Its agents will be stopped. The worktree \(screen.branch.map { "on branch “\($0)”" } ?? "") can be kept, or removed — removal never touches uncommitted changes."
        a.addButton(withTitle: "Close & keep worktree")
        a.addButton(withTitle: "Close & remove worktree")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: store.closeScreen(screen.id, removeWorktree: false)
        case .alertSecondButtonReturn: store.closeScreen(screen.id, removeWorktree: true)
        default: break
        }
    }

    private var isActive: Bool { screen.id == store.activeScreenID }
    private var waiting: Int { store.waitingCount(screen) }
    private var cost: Double { store.screenCost(screen) }

    var body: some View {
        HStack(spacing: 8) {
            if screen.isGitBacked {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
            }
            if editing {
                TextField("", text: $draft, onCommit: {
                    editing = false; store.renameScreen(screen.id, draft.trimmingCharacters(in: .whitespaces))
                }).textFieldStyle(.plain).font(Theme.mono(12.5)).foregroundStyle(Theme.ink)
            } else {
                Text(screen.name).font(Theme.mono(12.5, isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.ink : Theme.inkSoft).lineLimit(1)
                if showProject, let repo = screen.repoPath {
                    Text((repo as NSString).lastPathComponent).font(Theme.mono(10)).foregroundStyle(Theme.inkFaint)
                }
            }
            Spacer()
            if waiting > 0 { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
            if cost > 0 { Text(String(format: "$%.2f", cost)).font(Theme.mono(10)).foregroundStyle(Theme.inkFaint) }
            // Previously hidden unless store.screens.count > 1 — meant the
            // close button silently vanished with no explanation once you
            // were down to one screen, which read as "the close button
            // doesn't work." A real empty-state view already exists (see
            // CockpitView's ZStack) for zero screens, so there's no longer a
            // reason to prevent closing down to it.
            if hover || isActive {
                Button { confirmClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                    .help("Close “\(screen.name)”")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isActive ? Theme.accent.opacity(0.14) : (hover ? Theme.panel2 : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.select(screen.id) }
        .onTapGesture(count: 2) { draft = screen.name; editing = true }
        .onHover { hover = $0 }
        .padding(.leading, showProject ? 0 : 12)
        .contextMenu {
            Button("Rename") { draft = screen.name; editing = true }
            Button("Close…") { confirmClose() }
        }
    }
}

// MARK: - Terminal grid (one per screen, always mounted)

/// Arranges panes in the same √n-column grid as before, but as ONE flat
/// Layout instead of nested VStack/HStack ForEachs keyed by row index.
///
/// The nested version keyed its outer ForEach by row *offset*: when the pane
/// count changed, the column count changed too (columns = ceil(√n)), which
/// moved panes between rows — e.g. adding a 5th pane to 4 (2 cols) makes 3
/// cols, so pane C moves from row 1 to row 0. SwiftUI saw that as the pane
/// leaving one HStack and appearing in a different one, tore down its
/// TerminalPane (an NSViewRepresentable) as a result, and dismantleNSView
/// SIGHUP/SIGTERM'd that pane's whole process group — silently killing a
/// *different*, untouched pane's agent just because someone else's pane
/// count changed. A `Layout` container's subviews come from a single flat
/// ForEach with stable identity; only their position/size changes when the
/// grid reflows, never their identity, so this can't happen here.
private struct PaneGridLayout: Layout {
    static let gap: CGFloat = 1

    private static func grid(for count: Int) -> (columns: Int, rows: Int) {
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = count > 0 ? Int(ceil(Double(count) / Double(columns))) : 0
        return (columns, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    /// When set, every subview is proposed the FULL bounds — the maximized
    /// one renders there; the others stay mounted (never unmounted, so their
    /// agents keep running) but are made invisible/non-interactive by
    /// PaneCell's own opacity/allowsHitTesting, the same pattern the
    /// screens-switching ZStack already uses. Their exact placed frame
    /// doesn't matter once hidden that way, so giving everyone the same
    /// frame avoids needing a way to identify "which subview is which pane"
    /// inside a Layout (no LayoutValueKey needed).
    var isAnyMaximized: Bool = false

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        if isAnyMaximized {
            for subview in subviews {
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                               proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            }
            return
        }
        let (columns, rows) = Self.grid(for: n)
        let cellW = (bounds.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (bounds.height - Self.gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (index, subview) in subviews.enumerated() {
            let r = index / columns, c = index % columns
            let x = bounds.minX + CGFloat(c) * (cellW + Self.gap) + cellW / 2
            let y = bounds.minY + CGFloat(r) * (cellH + Self.gap) + cellH / 2
            subview.place(at: CGPoint(x: x, y: y), anchor: .center,
                           proposal: ProposedViewSize(width: cellW, height: cellH))
        }
    }
}

/// Shown when there are zero screens — a real reachable state now that
/// closing your last screen doesn't immediately recreate a default one.
private struct EmptyScreensCTA: View {
    @EnvironmentObject var store: CockpitStore
    @Binding var showingNewScreen: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("no screens yet").foregroundStyle(Theme.inkFaint).font(Theme.mono(13))
            HStack(spacing: 10) {
                FleetButton(title: "New Screen", systemImage: "plus", primary: true) { showingNewScreen = true }
                FleetButton(title: "Quick Claude", systemImage: "terminal") { _ = store.quickSpin(agent: "claude", repoPath: nil) }
                FleetButton(title: "Quick Codex", systemImage: "terminal") { _ = store.quickSpin(agent: "codex", repoPath: nil) }
            }
        }
    }
}

private struct ScreenGrid: View {
    @EnvironmentObject var store: CockpitStore
    let screen: Screen

    var body: some View {
        PaneGridLayout(isAnyMaximized: store.maximizedPane[screen.id] != nil) {
            ForEach(screen.panes) { pane in PaneCell(pane: pane, screenID: screen.id) }
        }
        // Layout containers size to their content by default (like the old
        // GeometryReader-less VStack would have) — GeometryReader was doing
        // double duty as "take all available space," not just supplying a
        // geometry value. Replicate that explicitly, or the grid shrink-wraps
        // instead of filling the pane area.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}

private struct PaneCell: View {
    @EnvironmentObject var store: CockpitStore
    let pane: PaneConfig
    let screenID: UUID
    @State private var editing = false
    @State private var draft = ""
    @State private var exitCode: Int32? = nil
    @State private var exited = false
    @State private var restartToken = 0
    @State private var resumeCommand: String? = nil

    private var stat: SessionStat? { store.statByPane[pane.id] }
    private var isMaximized: Bool { store.maximizedPane[screenID] == pane.id }
    private func toggleMaximize() {
        store.maximizedPane[screenID] = isMaximized ? nil : pane.id
        store.focusRequest = pane.id
    }
    private func confirmClosePane() {
        // Only ask for confirmation when there's something to lose — a pane
        // that's actively working or waiting on you. An idle/exited pane
        // closes immediately, same as before there was any per-pane close.
        if stat?.state == "working" || stat?.attention == true {
            let a = NSAlert()
            a.messageText = "Close “\(pane.name)”?"
            a.informativeText = "Its agent is still running and will be stopped."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        store.closePane(pane.id, in: screenID)
    }

    var body: some View {
        // VStack, not an overlay ZStack: the header takes its own row and the
        // terminal gets the *remaining* height, so nothing renders underneath
        // it. (An overlay looked identical at rest but clipped the terminal's
        // first line or two of real output — e.g. Claude Code's own banner.)
        VStack(spacing: 0) {
            header
            if store.isLocked(pane.id) {
                lockedPane
            } else {
                TerminalPane(pane: pane, focusRequest: $store.focusRequest, command: resumeCommand, onExit: { code in
                    exitCode = code; exited = true
                }, onTitle: { title in
                    store.autoName(pane: pane.id, in: screenID, title: title)
                })
                .id("\(pane.id.uuidString)-\(restartToken)")   // bump = fresh PTY
                .overlay { if exited { restartOverlay } }
            }
        }
        .clipped()
        .overlay(Rectangle().stroke(stat?.attention == true ? Theme.accent : Theme.line,
                                     lineWidth: stat?.attention == true ? 2 : 1))
        // When a DIFFERENT pane in this screen is maximized, stay mounted
        // (agent keeps running) but go invisible/non-interactive — the same
        // pattern the screens ZStack uses for background screens.
        .opacity(hiddenByMaximize ? 0 : 1)
        .allowsHitTesting(!hiddenByMaximize)
        .zIndex(isMaximized ? 1 : 0)
    }
    private var hiddenByMaximize: Bool {
        if let m = store.maximizedPane[screenID] { return m != pane.id }
        return false
    }

    private var lockedPane: some View {
        ZStack {
            Theme.ground
            VStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 16)).foregroundStyle(Theme.inkFaint)
                Text("Over the free \(store.freePaneLimit)-pane limit").font(Theme.mono(11.5)).foregroundStyle(Theme.inkSoft)
                Text("Layout kept — nothing was deleted.").font(Theme.mono(10)).foregroundStyle(Theme.inkFaint)
                FleetButton(title: "Unlock", primary: true) { store.upgradeReason = ""; store.showUpgrade = true }
            }
        }
    }

    private var restartOverlay: some View {
        ZStack {
            Theme.ground.opacity(0.75)
            VStack(spacing: 10) {
                Text(exitCode == 0 ? "\(pane.command) exited" : "\(pane.command) exited · code \(exitCode ?? -1)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.inkSoft)
                HStack(spacing: 8) {
                    FleetButton(title: "Restart", systemImage: "arrow.clockwise", primary: true) {
                        resumeCommand = nil; exited = false; restartToken += 1
                    }
                    if pane.command.hasPrefix("claude") && !pane.command.contains("--continue") {
                        FleetButton(title: "Resume last chat", systemImage: "clock.arrow.circlepath") {
                            resumeCommand = pane.command + " --continue"; exited = false; restartToken += 1
                        }.help("Runs `claude --continue` — picks up the most recent conversation in this folder")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                if editing {
                    TextField("name", text: $draft, onCommit: commit)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11, .medium)).foregroundStyle(Theme.ink)
                        .frame(width: 120)
                } else {
                    Text(pane.name)
                        .font(Theme.mono(11, .medium)).foregroundStyle(Theme.inkSoft)
                        .onTapGesture(count: 2) { draft = pane.name; editing = true }
                }
                if stat?.attention == true {
                    Text("WAITING").font(Theme.mono(9, .bold)).foregroundStyle(Theme.accent)
                }
                Spacer()
                if let m = stat?.model { Text(m).font(Theme.mono(10)).foregroundStyle(Theme.inkFaint) }
                Button { toggleMaximize() } label: {
                    Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                .help(isMaximized ? "Restore" : "Maximize this pane")
                Button { confirmClosePane() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                    .help("Close this pane")
            }
            // Rate limits deliberately don't repeat here — they're
            // account-wide, so every pane on the same account showed the
            // identical number, and a pane with no reading yet just looked
            // like it disagreed with the others. See the toolbar's
            // account-grouped rate chips instead.
            if let s = stat, (s.costUsd ?? 0) > 0 || (s.ctxPct ?? 0) > 0 {
                HStack(spacing: 12) {
                    if let cost = s.costUsd, cost > 0 {
                        statChip("$" + String(format: "%.2f", cost), costColor(cost))
                    }
                    if let ctx = s.ctxPct, ctx > 0 { statChip("ctx \(ctx)%", ctxColor(ctx)) }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.panel)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.mono(9.5, .medium)).foregroundStyle(color)
    }
    private func ctxColor(_ c: Int) -> Color { c >= 85 ? Theme.red : c >= 60 ? Theme.amber : Theme.inkFaint }

    private var dotColor: Color {
        switch stat?.state {
        case "waiting": return Theme.accent
        case "idle": return Theme.inkFaint
        case "working": return .green
        default: return Theme.inkFaint.opacity(0.5)
        }
    }
    private func costColor(_ c: Double) -> Color { c >= 15 ? Theme.red : c >= 5 ? Theme.amber : Theme.inkFaint }
    private func commit() { editing = false; store.rename(pane: pane.id, in: screenID, to: draft.trimmingCharacters(in: .whitespaces)) }
}

// MARK: - New screen sheet

private struct NewScreenSheet: View {
    @EnvironmentObject var store: CockpitStore
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var repoPath = ""
    @State private var branch = ""
    @State private var baseBranch = "main"
    @State private var paneCount = 2
    @State private var command = "claude"
    @State private var useGit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("New Screen").font(Theme.mono(15, .bold)).foregroundStyle(Theme.ink)
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
            }
            TextField("Name (e.g. \"payments-fix\")", text: $name).textFieldStyle(FleetFieldStyle())
            Toggle("Isolate in its own git worktree", isOn: $useGit).tint(Theme.accent)
            if useGit {
                HStack {
                    TextField("Repo path (e.g. ~/Projects/fleet)", text: $repoPath).textFieldStyle(FleetFieldStyle())
                    FleetButton(title: "Choose…") { pickFolder() }
                }
                HStack {
                    TextField("Branch (blank = derive from name)", text: $branch).textFieldStyle(FleetFieldStyle())
                    TextField("Base", text: $baseBranch).textFieldStyle(FleetFieldStyle()).frame(width: 90)
                }
                Text("Creates repo-worktrees/<branch> next to the repo, checked out on that branch — a separate copy of the files so this screen's agent never collides with another screen's.")
                    .font(.caption).foregroundStyle(Theme.inkFaint)
            }
            HStack {
                Text("Panes").foregroundStyle(Theme.inkSoft)
                MiniStepper(value: $paneCount)
                Spacer()
                Text("Command").foregroundStyle(Theme.inkSoft)
                Chip(options: [("claude", "claude"), ("codex", "codex"), ("custom", "custom…")], selection: $command)
                if command == "custom" { TextField("command", text: $command).textFieldStyle(FleetFieldStyle()).frame(width: 120) }
            }
            HStack {
                Spacer()
                FleetButton(title: "Cancel") { isPresented = false }
                FleetButton(title: "Create", primary: true) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (useGit && repoPath.isEmpty))
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty || (useGit && repoPath.isEmpty) ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
        .foregroundStyle(Theme.ink)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { repoPath = url.path }
    }
    private func create() {
        store.addScreen(name: name, repoPath: useGit ? repoPath : nil,
                         branch: branch.isEmpty ? nil : branch, baseBranch: baseBranch,
                         paneCount: paneCount, command: command == "custom" ? "claude" : command)
        isPresented = false
    }
}


// MARK: - Upgrade / license sheet

private struct UpgradeSheet: View {
    @EnvironmentObject var store: CockpitStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var busy = false
    @State private var message: String? = nil
    @State private var ok = false

    private var checkout: URL? {
        let u = LicenseManager.product.checkoutUrl
        return u.isEmpty ? nil : URL(string: u)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Fleet Pro").font(Theme.mono(15, .bold)).foregroundStyle(Theme.ink)
                Circle().fill(store.entitlement == .pro ? Theme.accent : Theme.amber).frame(width: 5, height: 5)
                Text(store.entitlement.label).font(Theme.mono(11)).foregroundStyle(Theme.inkFaint)
            }
            if !store.upgradeReason.isEmpty {
                Text(store.upgradeReason).font(Theme.mono(11.5)).foregroundStyle(Theme.amber)
            }

            if store.entitlement == .pro {
                Text("Thanks for supporting Fleet. Your license is active on this Mac and shared with the fleet CLI.")
                    .font(.callout).foregroundStyle(Theme.inkSoft)
                HStack {
                    FleetButton(title: "Deactivate this Mac") {
                        busy = true
                        Task { message = await store.deactivateLicense(); ok = message == nil; busy = false
                               if ok { message = "Deactivated — the seat is free to use elsewhere." } }
                    }
                    Spacer()
                    FleetButton(title: "Done", primary: true) { dismiss() }
                }
            } else {
                Text("Free runs \(store.freePaneLimit) panes. Pro is a one-time purchase: up to 16 panes per screen, unlimited screens, works on 3 of your Macs, includes every future 0.x update.")
                    .font(.callout).foregroundStyle(Theme.inkSoft)

                HStack {
                    if let url = checkout {
                        FleetButton(title: "Buy Fleet Pro", systemImage: "arrow.up.right", primary: true) { NSWorkspace.shared.open(url) }
                    } else {
                        Text("Checkout isn't live yet.").font(Theme.mono(11)).foregroundStyle(Theme.inkFaint)
                    }
                    Spacer()
                }

                Rectangle().fill(Theme.line).frame(height: 1)
                Text("Already bought?").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.inkFaint)
                HStack {
                    TextField("License key", text: $key).textFieldStyle(FleetFieldStyle())
                    FleetButton(title: busy ? "Activating…" : "Activate", primary: true) {
                        busy = true; message = nil
                        Task {
                            let err = await store.activateLicense(key)
                            busy = false; ok = err == nil
                            message = err ?? "Activated — thank you!"
                            if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() } }
                        }
                    }.disabled(busy)
                }
                HStack { Spacer(); FleetButton(title: "Not now") { dismiss() } }
            }

            if let m = message {
                Text(m).font(Theme.mono(11.5)).foregroundStyle(ok ? Theme.accent : Theme.red)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.panel)
        .foregroundStyle(Theme.ink)
    }
}


// MARK: - Spend report

private struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(project: String, sessions: Int, day: Double, week: Double)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Spend").font(Theme.mono(15, .bold)).foregroundStyle(Theme.ink)
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
            }
            if rows.isEmpty {
                Text("No billed sessions yet. Turn on the HUD (toolbar) and run a Claude Code session.")
                    .font(.callout).foregroundStyle(Theme.inkSoft)
            } else {
                VStack(spacing: 0) {
                    row("PROJECT", "SESSIONS", "24H", "7D", header: true)
                    ForEach(rows, id: \.project) { r in
                        row(r.project, "\(r.sessions)", money(r.day), money(r.week))
                    }
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
                    row("total", "\(rows.reduce(0) { $0 + $1.sessions })",
                        money(rows.reduce(0) { $0 + $1.day }), money(rows.reduce(0) { $0 + $1.week }), bold: true)
                }
            }
            Text("Each session's cost is its running total, counted in the window of its last activity.")
                .font(.caption).foregroundStyle(Theme.inkFaint)
            HStack { Spacer(); FleetButton(title: "Done", primary: true) { dismiss() } }
        }
        .padding(20).frame(width: 520)
        .background(Theme.panel).foregroundStyle(Theme.ink)
        .onAppear(perform: load)
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    private func row(_ a: String, _ b: String, _ c: String, _ d: String, header: Bool = false, bold: Bool = false) -> some View {
        HStack {
            Text(a).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(width: 80, alignment: .trailing)
            Text(c).frame(width: 80, alignment: .trailing)
            Text(d).frame(width: 80, alignment: .trailing)
        }
        .font(Theme.mono(header ? 10 : 12, header || bold ? .semibold : .regular))
        .foregroundStyle(header ? Theme.inkFaint : Theme.ink)
        .padding(.vertical, 4)
    }

    private func load() {
        let week = SessionStats.load(maxAgeHours: 24 * 7).filter { ($0.costUsd ?? 0) > 0 }
        let cutoff = Date().timeIntervalSince1970 - 86_400
        var by: [String: (n: Int, day: Double, week: Double)] = [:]
        for s in week {
            let k = (s.dir as NSString).lastPathComponent
            var v = by[k] ?? (0, 0, 0)
            v.n += 1; v.week += s.costUsd ?? 0
            if (s.updated ?? 0) > cutoff { v.day += s.costUsd ?? 0 }
            by[k] = v
        }
        rows = by.map { (project: $0.key, sessions: $0.value.n, day: $0.value.day, week: $0.value.week) }
            .sorted { $0.week > $1.week }
    }
}
