import SwiftUI
import AppKit

private let accent = Color(red: 0.37, green: 0.89, blue: 0.76)

struct CockpitView: View {
    @EnvironmentObject var store: CockpitStore
    @State private var showingNewScreen = false

    var body: some View {
        VStack(spacing: 0) {
            screenTabs
            Divider()
            toolbar
            Divider()
            // Every screen's grid stays mounted (its PTYs keep running in the
            // background) — switching tabs only changes which one is visible.
            ZStack {
                ForEach(store.screens) { screen in
                    ScreenGrid(screen: screen)
                        .opacity(screen.id == store.activeScreenID ? 1 : 0)
                        .allowsHitTesting(screen.id == store.activeScreenID)
                        .zIndex(screen.id == store.activeScreenID ? 1 : 0)
                }
            }
        }
        .background(Color(white: 0.09))
        .sheet(isPresented: $showingNewScreen) {
            NewScreenSheet(isPresented: $showingNewScreen)
        }
    }

    // MARK: tab bar — one tab per independent screen/worktree

    private var screenTabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.screens) { screen in
                        ScreenTab(screen: screen, isActive: screen.id == store.activeScreenID)
                            .onTapGesture { store.activeScreenID = screen.id }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            Button { showingNewScreen = true } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .help("New screen — its own terminal grid, optionally its own git worktree")
        }
        .background(Color(white: 0.14))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            if let s = store.activeScreen {
                if s.isGitBacked {
                    Label(s.branch ?? "?", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Button {
                        store.sync(s.id)
                    } label: { Label("Sync \(s.baseBranch)", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(store.gitBusy.contains(s.id))
                    Button {
                        store.push(s.id)
                    } label: { Label("Push", systemImage: "arrow.up.circle") }
                        .disabled(store.gitBusy.contains(s.id))
                    if let log = store.gitLog[s.id] {
                        Text(log).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Divider().frame(height: 16)
                }

                HStack(spacing: 6) {
                    Text("panes").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { s.panes.count },
                                           set: { store.setPaneCount($0, in: s.id) }),
                            in: 1...16) { Text("\(s.panes.count)").monospacedDigit() }
                        .labelsHidden()
                }
            }

            Picker("", selection: $store.powerMode) {
                ForEach(PowerManager.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Native power assertion — no caffeinate, no screen blanking")

            if !store.displays.isEmpty {
                Picker("", selection: Binding(get: { store.pinnedDisplay ?? store.displays.first?.id ?? 0 },
                                              set: { store.pinnedDisplay = $0 })) {
                    ForEach(store.displays) { d in Text(d.name + (d.isMain ? " ✦" : "")).tag(d.id) }
                }
                .fixedSize()
                .help("Pin the cockpit to this display; it never follows a display that disappears")
            }

            Spacer()

            let totalWaiting = store.screens.reduce(0) { $0 + store.waitingCount($1) }
            if totalWaiting > 0 {
                Button { store.jumpToWaiting() } label: { Label("\(totalWaiting) waiting", systemImage: "bell.badge.fill") }
                    .tint(accent)
            }
            Text(String(format: "$%.2f today", store.totalToday))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                .help("Total Claude Code spend in the last 24h across all screens")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(white: 0.12))
    }
}

private struct ScreenTab: View {
    @EnvironmentObject var store: CockpitStore
    let screen: Screen
    let isActive: Bool
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            if screen.isGitBacked { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)) }
            if editing {
                TextField("", text: $draft, onCommit: {
                    editing = false; store.renameScreen(screen.id, draft.trimmingCharacters(in: .whitespaces))
                }).textFieldStyle(.plain).frame(width: 90)
            } else {
                Text(screen.name).onTapGesture(count: 2) { draft = screen.name; editing = true }
            }
            let waiting = store.waitingCount(screen)
            if waiting > 0 { Circle().fill(accent).frame(width: 6, height: 6) }
            if store.screens.count > 1 {
                Button {
                    store.closeScreen(screen.id, removeWorktree: false)
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).opacity(0.5).font(.system(size: 9))
            }
        }
        .font(.system(size: 12, weight: isActive ? .semibold : .regular, design: .monospaced))
        .foregroundStyle(isActive ? Color.white : Color.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isActive ? Color.white.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The tiled terminal grid for one screen.
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
