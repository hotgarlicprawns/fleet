import SwiftUI

/// Fleet's Settings window (⌘,). Houses controls that used to crowd the
/// main toolbar — power mode, display pin, HUD toggle — plus license
/// management. An "Accounts" tab (for running multiple Claude/Codex
/// subscriptions side by side) is planned but not built yet: it needs a
/// real Account data model and per-pane environment wiring first, and
/// whether extra accounts are a Pro-gated feature is a product decision,
/// not a technical one — deliberately not guessed here.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            LicenseSettingsTab()
                .tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var store: CockpitStore

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
                Text("Native power assertion — no caffeinate, no screen blanking.")
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

private struct IntegrationsSettingsTab: View {
    @EnvironmentObject var store: CockpitStore

    private var leanSavingsFile: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("fleet/lean-savings.json")
    }
    private var leanInstalled: Bool { FileManager.default.fileExists(atPath: leanSavingsFile.path) }

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
            Section("fleet-lean — token-saving tools") {
                if leanInstalled {
                    Label("Installed — real savings tracked at ~/.config/fleet/lean-savings.json", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent).font(.callout)
                } else {
                    Label("Not installed", systemImage: "circle").font(.callout).foregroundStyle(.secondary)
                    Text("Free, no account, works standalone. Install from a Claude Code session:")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text("/plugin install fleet-lean@fleet-marketplace")
                            .font(Theme.mono(11)).textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("/plugin install fleet-lean@fleet-marketplace", forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
                    }
                }
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
