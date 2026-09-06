import SwiftUI
import AppKit

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
                if !store.hudInstalled { hudOnboardingBanner }
                ZStack {
                    ForEach(store.screens) { screen in
                        ScreenGrid(screen: screen)
                            .opacity(screen.id == store.activeScreenID ? 1 : 0)
                            .allowsHitTesting(screen.id == store.activeScreenID)
                            .zIndex(screen.id == store.activeScreenID ? 1 : 0)
                    }
                    if store.screens.isEmpty {
                        Text("no screens yet — press + in the sidebar")
                            .foregroundStyle(Theme.inkFaint).font(Theme.mono(13))
                    }
                }
            }
        }
        .background(Theme.ground)
        .sheet(isPresented: $showingNewScreen) { NewScreenSheet(isPresented: $showingNewScreen) }
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
                MiniStepper(value: Binding(get: { s.panes.count }, set: { store.setPaneCount($0, in: s.id) }))
            } else {
                Text("fleet").font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.inkFaint).fixedSize()
            }

            Spacer(minLength: 8)

            Segmented(options: PowerManager.Mode.allCases.map { ($0, $0.rawValue) }, selection: $store.powerMode)
                .help("Native power assertion — no caffeinate, no screen blanking")

            if !store.displays.isEmpty {
                Chip(options: store.displays.map { ($0.id, shortDisplayName($0)) },
                     selection: Binding(get: { store.pinnedDisplay ?? store.displays.first?.id ?? 0 },
                                        set: { store.pinnedDisplay = $0 }))
                    .help("Pin to this display; falls back if it disappears")
            }

            let totalWaiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
            if totalWaiting > 0 {
                FleetButton(title: "\(totalWaiting) waiting", systemImage: "bell.badge.fill", primary: true) { store.jumpToWaiting() }
            }
            Text(String(format: "$%.2f", store.totalToday))
                .font(Theme.mono(12)).foregroundStyle(Theme.inkFaint).lineLimit(1).fixedSize()
                .help("Total Claude Code spend in the last 24h")

            Menu {
                if store.hudInstalled { Button("Turn off HUD") { store.uninstallHUD() } }
                else { Button("Turn on HUD") { store.installHUD() } }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(store.hudInstalled ? Theme.accent : Theme.inkFaint).frame(width: 6, height: 6)
                    Text("HUD").font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.inkFaint)
                }
            }.menuStyle(.borderlessButton).fixedSize()
                .help(store.hudInstalled ? "HUD is on — click to turn off" : "HUD is off — click to turn on")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.panel)
    }

    private func shortDisplayName(_ d: DisplayInfo) -> String {
        var n = d.name
        n = n.replacingOccurrences(of: " Retina Display", with: "").replacingOccurrences(of: " Display", with: "")
        if n.count > 16 { n = String(n.prefix(15)) + "…" }
        return n + (d.isMain ? " ✦" : "")
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
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("fleet").font(Theme.mono(11, .medium)).foregroundStyle(Theme.inkSoft)
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
            if hover && store.screens.count > 1 {
                Button { store.closeScreen(screen.id, removeWorktree: false) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isActive ? Theme.accent.opacity(0.14) : (hover ? Theme.panel2 : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.activeScreenID = screen.id }
        .onTapGesture(count: 2) { draft = screen.name; editing = true }
        .onHover { hover = $0 }
        .padding(.leading, showProject ? 0 : 12)
    }
}

// MARK: - Terminal grid (one per screen, always mounted)

private struct ScreenGrid: View {
    @EnvironmentObject var store: CockpitStore
    let screen: Screen

    private var columns: Int { max(1, Int(ceil(sqrt(Double(screen.panes.count))))) }
    private var rows: [[PaneConfig]] {
        stride(from: 0, to: screen.panes.count, by: columns).map {
            Array(screen.panes[$0 ..< min($0 + columns, screen.panes.count)])
        }
    }

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 1) {
                        ForEach(row) { pane in PaneCell(pane: pane, screenID: screen.id) }
                    }
                }
            }
            .background(Theme.ground)
        }
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

    private var stat: SessionStat? { store.statByPane[pane.id] }

    var body: some View {
        // VStack, not an overlay ZStack: the header takes its own row and the
        // terminal gets the *remaining* height, so nothing renders underneath
        // it. (An overlay looked identical at rest but clipped the terminal's
        // first line or two of real output — e.g. Claude Code's own banner.)
        VStack(spacing: 0) {
            header
            TerminalPane(pane: pane, focusRequest: $store.focusRequest) { code in
                exitCode = code; exited = true
            }
            .id("\(pane.id.uuidString)-\(restartToken)")   // bump = fresh PTY
            .overlay { if exited { restartOverlay } }
        }
        .clipped()
        .overlay(Rectangle().stroke(stat?.attention == true ? Theme.accent : Theme.line,
                                     lineWidth: stat?.attention == true ? 2 : 1))
    }

    private var restartOverlay: some View {
        ZStack {
            Theme.ground.opacity(0.75)
            VStack(spacing: 10) {
                Text(exitCode == 0 ? "\(pane.command) exited" : "\(pane.command) exited · code \(exitCode ?? -1)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.inkSoft)
                FleetButton(title: "Restart", systemImage: "arrow.clockwise", primary: true) {
                    exited = false; restartToken += 1
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
            }
            if let s = stat, (s.costUsd ?? 0) > 0 || (s.ctxPct ?? 0) > 0 || s.rl5h != nil {
                HStack(spacing: 12) {
                    if let cost = s.costUsd, cost > 0 {
                        statChip("$" + String(format: "%.2f", cost), costColor(cost))
                    }
                    if let ctx = s.ctxPct, ctx > 0 { statChip("ctx \(ctx)%", ctxColor(ctx)) }
                    if let rl5 = s.rl5h { statChip("5h \(rl5)%", rateColor(rl5)) }
                    if let rl7 = s.rl7d { statChip("7d \(rl7)%", rateColor(rl7)) }
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
    private func rateColor(_ p: Int) -> Color { p >= 90 ? Theme.red : p >= 70 ? Theme.amber : Theme.inkFaint }

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
            TextField("Name (e.g. \"payments-fix\")", text: $name)
            Toggle("Isolate in its own git worktree", isOn: $useGit).tint(Theme.accent)
            if useGit {
                HStack {
                    TextField("Repo path (e.g. ~/Projects/fleet)", text: $repoPath)
                    FleetButton(title: "Choose…") { pickFolder() }
                }
                HStack {
                    TextField("Branch (blank = derive from name)", text: $branch)
                    TextField("Base", text: $baseBranch).frame(width: 90)
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
                if command == "custom" { TextField("command", text: $command).frame(width: 120) }
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
