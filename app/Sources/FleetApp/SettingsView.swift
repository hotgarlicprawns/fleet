import SwiftUI

/// Fleet's Settings window (⌘,). Houses controls that used to crowd the
/// main toolbar — power mode, display pin, HUD toggle — plus accounts
/// (several Claude/Codex subscriptions side by side) and license management.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            LicenseSettingsTab()
                .tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var store: CockpitStore

    private var powerModeCaption: String {
        switch store.powerMode {
        case .displayOn: return "Native power assertion (no caffeinate) — the display stays on while sessions run."
        case .systemOnly: return "Your Mac keeps working, but the display can sleep on its own — use Screen blanking below to control that explicitly instead."
        case .off: return "No assertion held — your Mac's own sleep settings apply."
        }
    }

    private func shortDisplayName(_ d: DisplayInfo) -> String {
        var n = d.name
        n = n.replacingOccurrences(of: " Retina Display", with: "").replacingOccurrences(of: " Display", with: "")
        if n.count > 16 { n = String(n.prefix(15)) + "…" }
        return n + (d.isMain ? " ✦" : "")
    }

    var body: some View {
        Form {
            Section("Power") {
                HStack {
                    Text("Mode")
                    Spacer()
                    Segmented(options: PowerManager.Mode.allCases.map { ($0, $0.rawValue) }, selection: $store.powerMode)
                }
                Text(powerModeCaption)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Screen blanking") {
                HStack {
                    Text("Blank the display")
                    Spacer()
                    FleetButton(title: "Now", systemImage: "moon.fill") { store.blankNow() }
                        .help("pmset displaysleepnow — any key or mouse movement wakes it; arrangement untouched")
                }
                Toggle("Auto-blank after idle time (Pro)", isOn: Binding(
                    get: { store.smartBlankEnabled },
                    set: { store.smartBlankEnabled = $0 }
                ))
                if store.smartBlankEnabled {
                    HStack {
                        Text("Idle threshold")
                        Spacer()
                        Stepper("\(store.blankAfterMinutes) min", value: $store.blankAfterMinutes, in: 1...60)
                    }
                }
                Text("Blanks automatically once you've been idle that long, and wakes the instant a session needs your input — same as `fleet watch` in the CLI.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !store.displays.isEmpty {
                Section("Display") {
                    HStack {
                        Text("Pin window to")
                        Spacer()
                        Chip(options: store.displays.map { ($0.id, shortDisplayName($0)) },
                             selection: Binding(get: { store.pinnedDisplay ?? store.displays.first?.id ?? 0 },
                                                 set: { store.pinnedDisplay = $0 }))
                    }
                    Text("Falls back automatically if this display disappears.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountsSettingsTab: View {
    @EnvironmentObject var store: CockpitStore
    @State private var newName = ""
    @State private var newKind: Account.Kind = .claude

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    Text("Default login").font(.callout)
                    Spacer()
                    Text("~/.claude · ~/.codex").font(Theme.mono(10.5)).foregroundStyle(.secondary)
                }
                ForEach(store.accounts) { a in
                    HStack {
                        Image(systemName: a.kind == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).font(.callout)
                            Text("\(a.kind.rawValue) · \(abbreviate(a.configDir))")
                                .font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Sign in") { store.openSignIn(a) }
                            .help(a.kind == .claude ? "Opens a pane running claude on this account — it walks you through login" : "Opens a pane running codex login on this account")
                        Button(role: .destructive) { store.removeAccount(a.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Forget this account (its folder is kept on disk)")
                    }
                }
            } header: { Text("Accounts") } footer: {
                Text("Each account is its own Claude Code (CLAUDE_CONFIG_DIR) or Codex (CODEX_HOME) folder with its own login, history and rate limits. New accounts copy your settings and share your installed plugins. Pick a pane's account from the name next to its model; the top bar shows 5h/7d limits per account.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Add account") {
                HStack {
                    TextField("Name, e.g. work", text: $newName).textFieldStyle(.roundedBorder)
                    Picker("", selection: $newKind) {
                        ForEach(Account.Kind.allCases, id: \.self) { Text($0 == .claude ? "Claude Code" : "Codex").tag($0) }
                    }.labelsHidden().fixedSize()
                    Button("Add") {
                        if let a = store.addAccount(name: newName, kind: newKind) { newName = ""; store.openSignIn(a) }
                    }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Adding opens a sign-in pane right away.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationsSettingsTab: View {
    @EnvironmentObject var store: CockpitStore

    var body: some View {
        Form {
            Section("HUD") {
                Toggle("Cost, context and rate-limit HUD", isOn: Binding(
                    get: { store.hudInstalled },
                    set: { $0 ? store.installHUD() : store.uninstallHUD() }
                ))
                Text("Wires a statusLine into Claude Code. Your previous statusLine, if any, is kept and restored on removal.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("fleet-lean (experimental)") {
                Text("Our own A/B eval found fleet-lean does not reduce cost versus current Claude Code — it came out about 11% more expensive on real tasks, because Claude Code already searches and edits efficiently through Bash. Fleet doesn't show a savings number for it. Details: plugin-lean/eval/RESULTS.md in the Fleet repo.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LicenseSettingsTab: View {
    @EnvironmentObject var store: CockpitStore
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?

    private var checkout: URL? {
        let u = LicenseManager.product.checkoutUrl
        return u.isEmpty ? nil : URL(string: u)
    }

    var body: some View {
        Form {
            Section("Fleet Pro") {
                HStack(spacing: 8) {
                    Circle().fill(store.entitlement == .pro ? Theme.accent : Theme.amber).frame(width: 6, height: 6)
                    Text(store.entitlement.label).font(.callout)
                }
                if store.entitlement == .pro {
                    Button("Deactivate this Mac") {
                        busy = true
                        Task {
                            message = await store.deactivateLicense()
                            busy = false
                        }
                    }.disabled(busy)
                } else {
                    HStack {
                        SecureField("License key", text: $key).textFieldStyle(.roundedBorder)
                        Button("Activate") {
                            busy = true
                            Task {
                                message = await store.activateLicense(key)
                                busy = false
                            }
                        }.disabled(key.isEmpty || busy)
                    }
                    if let url = checkout {
                        Link("Buy Fleet Pro", destination: url)
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
