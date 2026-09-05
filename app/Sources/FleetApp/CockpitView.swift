import SwiftUI
import AppKit

private let accent = Color(red: 0.37, green: 0.89, blue: 0.76)
private let codexColor = Color(red: 0.95, green: 0.58, blue: 0.29)

struct CockpitView: View {
    @EnvironmentObject var store: CockpitStore
    @State private var showingNewScreen = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(showingNewScreen: $showingNewScreen)
                .frame(width: 264)
                .background(Color(white: 0.08))
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                ZStack {
                    ForEach(store.screens) { screen in
                        ScreenGrid(screen: screen)
                            .opacity(screen.id == store.activeScreenID ? 1 : 0)
                            .allowsHitTesting(screen.id == store.activeScreenID)
                            .zIndex(screen.id == store.activeScreenID ? 1 : 0)
                    }
                    if store.screens.isEmpty {
                        Text("No screens yet — press \"+\" in the sidebar")
                            .foregroundStyle(.secondary).font(.system(size: 13, design: .monospaced))
                    }
                }
            }
        }
        .background(Color(white: 0.09))
        .sheet(isPresented: $showingNewScreen) {
            NewScreenSheet(isPresented: $showingNewScreen)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            if let s = store.activeScreen {
                Text(s.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                if s.isGitBacked {
                    Label(s.branch ?? "?", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Button { store.sync(s.id) } label: { Label("Sync \(s.baseBranch)", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(store.gitBusy.contains(s.id))
                    Button { store.push(s.id) } label: { Label("Push", systemImage: "arrow.up.circle") }
                        .disabled(store.gitBusy.contains(s.id))
                    if let log = store.gitLog[s.id] {
                        Text(log).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Divider().frame(height: 16)
                }
                HStack(spacing: 6) {
                    Text("panes").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { s.panes.count }, set: { store.setPaneCount($0, in: s.id) }),
                            in: 1...16) { Text("\(s.panes.count)").monospacedDigit() }.labelsHidden()
                }
            } else {
                Text("fleet").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $store.powerMode) {
                ForEach(PowerManager.Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize()
                .help("Native power assertion — no caffeinate, no screen blanking")

            if !store.displays.isEmpty {
                Picker("", selection: Binding(get: { store.pinnedDisplay ?? store.displays.first?.id ?? 0 },
                                              set: { store.pinnedDisplay = $0 })) {
                    ForEach(store.displays) { d in Text(d.name + (d.isMain ? " ✦" : "")).tag(d.id) }
                }.fixedSize().help("Pin to this display; falls back if it disappears")
            }

            let totalWaiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
            if totalWaiting > 0 {
                Button { store.jumpToWaiting() } label: { Label("\(totalWaiting) waiting", systemImage: "bell.badge.fill") }.tint(accent)
            }
            Text(String(format: "$%.2f today", store.totalToday))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(white: 0.12))
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

            HStack {
                Text("fleet").font(.system(size: 15, weight: .bold, design: .monospaced))
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                let waiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
                Button { store.jumpToWaiting() } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell").font(.system(size: 13))
                        if waiting > 0 { Circle().fill(accent).frame(width: 6, height: 6).offset(x: 2, y: -1) }
                    }
                }.buttonStyle(.plain).disabled(waiting == 0)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)

            SidebarRow(icon: "plus.circle.fill", label: "New Screen", iconColor: accent) { showingNewScreen = true }
                .padding(.horizontal, 8)

            Divider().padding(.top, 10)

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
            Divider()
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("fleet").font(.system(size: 11, weight: .medium, design: .monospaced))
                Spacer()
                Text(String(format: "$%.2f", store.totalToday))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary).opacity(0.6)
            .padding(.horizontal, 8)
    }
}

private struct SidebarRow: View {
    let icon: String; let label: String; var iconColor: Color = .secondary
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(iconColor).frame(width: 16)
                Text(label).font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hover ? Color.white.opacity(0.06) : .clear)
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
                .font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 10)
            Image(systemName: group.id.isEmpty ? "tray" : "folder.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer()
            if hover {
                spinButton(agent: "claude", tint: accent, glyph: "C")
                spinButton(agent: "codex", tint: codexColor, glyph: "X")
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
            Text(glyph).font(.system(size: 9, weight: .bold, design: .monospaced))
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
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if editing {
                TextField("", text: $draft, onCommit: {
                    editing = false; store.renameScreen(screen.id, draft.trimmingCharacters(in: .whitespaces))
                }).textFieldStyle(.plain).font(.system(size: 12.5))
            } else {
                Text(screen.name).font(.system(size: 12.5, weight: isActive ? .semibold : .regular)).lineLimit(1)
                if showProject, let repo = screen.repoPath {
                    Text((repo as NSString).lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if waiting > 0 { Circle().fill(accent).frame(width: 6, height: 6) }
            if cost > 0 { Text(String(format: "$%.2f", cost)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            if hover && store.screens.count > 1 {
                Button { store.closeScreen(screen.id, removeWorktree: false) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isActive ? accent.opacity(0.16) : (hover ? Color.white.opacity(0.05) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.activeScreenID = screen.id }
        .onTapGesture(count: 2) { draft = screen.name; editing = true }
        .onHover { hover = $0 }
        .padding(.leading, showProject ? 0 : 12)
    }
}

// MARK: - Terminal grid (unchanged behaviour, one per screen, always mounted)

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
            .background(Color.black)
        }
    }
}

private struct PaneCell: View {
    @EnvironmentObject var store: CockpitStore
    let pane: PaneConfig
    let screenID: UUID
    @State private var editing = false
    @State private var draft = ""

    private var stat: SessionStat? { store.statByPane[pane.id] }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalPane(pane: pane, focusRequest: $store.focusRequest)
            header
        }
        .clipped()
        .overlay(Rectangle().stroke(stat?.attention == true ? accent : Color.white.opacity(0.06),
                                     lineWidth: stat?.attention == true ? 2 : 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            if editing {
                TextField("name", text: $draft, onCommit: commit)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 120)
            } else {
                Text(pane.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .onTapGesture(count: 2) { draft = pane.name; editing = true }
            }
            Spacer()
            if let s = stat {
                HStack(spacing: 10) {
                    if s.attention == true {
                        Text("WAITING").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                    }
                    if let m = s.model { Text(m).foregroundStyle(.secondary) }
                    if let cost = s.costUsd, cost > 0 { Text(String(format: "$%.2f", cost)).foregroundStyle(costColor(cost)) }
                    if let ctx = s.ctxPct, ctx > 0 { Text("ctx \(ctx)%").foregroundStyle(.secondary) }
                }
                .font(.system(size: 10, design: .monospaced))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dotColor: Color {
        switch stat?.state {
        case "waiting": return accent
        case "idle": return .gray
        case "working": return .green
        default: return .gray.opacity(0.5)
        }
    }
    private func costColor(_ c: Double) -> Color { c >= 15 ? .red : c >= 5 ? .orange : .secondary }
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
            Text("New Screen").font(.system(size: 15, weight: .semibold, design: .monospaced))
            TextField("Name (e.g. \"payments-fix\")", text: $name)
            Toggle("Isolate in its own git worktree", isOn: $useGit)
            if useGit {
                HStack {
                    TextField("Repo path (e.g. ~/Projects/fleet)", text: $repoPath)
                    Button("Choose…") { pickFolder() }
                }
                HStack {
                    TextField("Branch (blank = derive from name)", text: $branch)
                    TextField("Base", text: $baseBranch).frame(width: 90)
                }
                Text("Creates repo-worktrees/<branch> next to the repo, checked out on that branch — a separate copy of the files so this screen's agent never collides with another screen's.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Panes"); Stepper(value: $paneCount, in: 1...16) { Text("\(paneCount)").monospacedDigit() }.labelsHidden()
                Spacer()
                Text("Command")
                Picker("", selection: $command) {
                    Text("claude").tag("claude"); Text("codex").tag("codex"); Text("custom…").tag("custom")
                }.fixedSize()
                if command == "custom" { TextField("command", text: $command).frame(width: 120) }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (useGit && repoPath.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 460)
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
