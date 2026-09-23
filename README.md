# fleet

**A tiled cockpit for Claude Code and Codex on macOS** — a screen per task (each
on its own git worktree), the cost, context and rate limits of every session on
its pane, and a Mac that stays awake through long runs without touching your
monitor arrangement (the thing that matters when your laptop's built-in panel is
dead).

Two ways to run it, sharing one config (`~/.config/fleet/`) and one license:

- **Fleet.app** — the native app (`app/`): sidebar of projects and screens, real
  terminals, menu-bar item, ⌃⌥F hotkey. See [app/README.md](app/README.md).
- **`fleet` CLI** — the tmux-based version, for SSH and terminal purists.

```
fleet up             # tiled grid of `claude` sessions + power management + HUD
fleet next           # jump to the session that's waiting for you
fleet report         # spend, grouped by project
fleet watch          # stay awake, blank when idle, wake when a session needs you
fleet down           # tear it all down
```

## Install

```bash
# the app
cd app && ./make-dmg.sh && open Fleet-*.dmg        # drag Fleet to Applications

# the CLI
npm i -g fleet-cockpit        # (or, from a clone: npm link)
brew install tmux             # required by the CLI
brew install jq               # optional — faster HUD
brew install displayplacer    # optional — display profiles

fleet hud install    # wire the cost + context HUD into Claude Code (the app has a one-click banner)
fleet config         # panes, power mode, budget, theme — or `fleet gui` in a browser
fleet up
```

`fleet gui` opens a small local control panel (`127.0.0.1:7787`, localhost-only)
for the CLI's config; the app has its own settings built in.

Claude Code plugin (auto power-management + attention flags per session):

```
/plugin marketplace add hotgarlicprawns/fleet
/plugin install fleet@fleet-marketplace
```

## fleet-lean — experimental

A separate MIT plugin with two fused tools (`lean_search`, `lean_edit`). **It does not
currently save money:** a real A/B eval against plain Claude Code (same tasks, strict
verification, Claude Code's own cost numbers) found it ~11% *more* expensive, because
Claude Code already searches and edits efficiently through Bash. Method, per-version
numbers and transcripts: [plugin-lean/eval/](plugin-lean/eval/RESULTS.md). It stays in the
repo as a research track; re-run `node plugin-lean/eval/eval.js` before claiming otherwise.

## The HUD — cost & context per session

`fleet hud install` adds a statusLine to `~/.claude/settings.json` that both
renders `model · ctx% · $cost · rate-limits` **and** writes a JSON sidecar per
session to `~/.config/fleet/sessions/`. Your previous statusLine is saved and
restored by `fleet hud uninstall`.

fleet then paints every pane border:

```
 ● main · Sonnet 5 · $2.14 · ctx 47%          ▲ sidecar · Opus 5 · $11.90 ⚠ · ctx 73%
```

- **amber** past `budget.warnUsd`, **red** past `budget.capUsd`
- `● waiting` in cyan when that Claude needs your input (`fleet next` jumps there)
- `fleet report` / `fleet report week` totals spend by project

Data source: Claude Code's statusLine hook hands the script `.model.display_name`,
`.context_window.used_percentage`, `.cost.total_cost_usd`, `.rate_limits.*`.

## Named panes & templates — `~/.config/fleet/config.json`

```jsonc
{
  "panes": [
    { "name": "api",  "cwd": "~/work/api", "command": "claude", "accent": "cyan" },
    { "name": "web",  "cwd": "~/work/web", "command": "claude", "accent": "amber", "glyph": "▲" },
    { "name": "db",   "cwd": "~/work/db",  "command": "claude" }
  ],
  "layout": "tiled",
  "budget": { "warnUsd": 5, "capUsd": 15, "dailyUsd": 40 },
  "hud": { "enabled": true },
  "templates": {
    "review": { "panes": [ {"name":"pr","cwd":"~/work/web"}, {"name":"tests","cwd":"~/work/web"} ],
                "power": { "mode": "awake-on" } }
  },
  "ui": { "theme": "aurora" }
}
```

- `panes` may also be a plain number (`4`) for unnamed panes.
- `fleet up review` uses the template; `fleet name 2 hotfix` renames a live pane.
- `fleet resume` rebuilds the last layout (names + directories) after a reboot.
- accents: `cyan amber green magenta blue grey`

## Power modes

| mode | caffeinate | display | for |
|---|---|---|---|
| `awake-blank` | `-i -s` | blanks (now or after N min) | **long unattended runs** — default |
| `awake-on` | `-d -i -s` | stays on | watching it work |
| `prevent-all` | `-d -i -m -s` | stays on | disk-heavy builds |
| `off` | — | — | nothing |

`fleet watch` holds the awake lock, blanks the screen after `blankAfterMinutes`
of HID idle time, and **un-blanks the moment a session needs input**. The
built-in panel is never singled out or reconfigured — fleet only blanks all
displays, or (opt-in) applies a `displayplacer` profile you saved yourself.

## Lighter on memory

`fleet tune` sets `terminal.integrated.gpuAcceleration: "off"` in VS Code /
Cursor settings, and fleet sessions cap tmux `history-limit` at 8000 lines.
Inside Claude Code you can also run `/terminal-setup`.

## Pricing & licensing

14-day full trial, no card. Then:

| | Free | Pro — one-time ($24 launch, $39 after) |
|---|---|---|
| Panes | 3 in total (app) / 3 per `fleet up` (CLI) | up to 16 per screen, unlimited screens |
| HUD, spend report, git-worktree screens | ✓ | ✓ |
| Menu-bar item, ⌃⌥F hotkey | ✓ | ✓ |
| Smart-blank, display profiles, templates (CLI) | — | ✓ |
| Devices | — | 3 Macs |

The app and the CLI share `~/.config/fleet/trial.json` and `license.json`, so
one purchase unlocks both. Past the free cap the app keeps your layout and
shows the extra panes as locked placeholders — nothing is deleted, no agent is
started — and unlocking (or activating a key) starts them live.

```
fleet buy                        # checkout link
fleet license activate <key>     # or: Fleet.app > sidebar plan badge > Activate
fleet license deactivate         # free the seat when switching machines
```

Keys are checked against Dodo Payments' public endpoints (no secret ships in
either client) with a 7-day offline grace. Client-side checks deter casual
sharing; they are not DRM.

**`product.json`** is the single place to set the checkout URL, API host, trial
length and free limit; the app bundles it and the CLI reads it. Until
`checkoutUrl` is filled in, the upgrade sheet says checkout isn't live.

**Owner override:** `touch ~/.config/fleet/owner` treats that Mac as Pro in both
the app and the CLI (for the developer's own machine and the test suite).

## Distribution

| Artifact | How | Status |
|---|---|---|
| `Fleet-<v>.dmg` | `app/make-dmg.sh` (ad-hoc), or with `FLEET_SIGN_ID` + `FLEET_NOTARY_PROFILE` for a signed, notarized build | script tested unsigned; signing/notarizing needs your Developer ID |
| `fleet-cockpit` on npm | `npm publish` (tarball verified: 17 files, installs and runs from a clean prefix) | unpublished |
| Homebrew | `packaging/homebrew/` — a formula (CLI) and a cask (app), both with placeholders | untested until artifacts exist |
| Release automation | `.github/workflows/release.yml` — tag `v*` builds, signs, notarizes, releases, publishes | written, not yet run |

Naming note: `fleet` is also JetBrains Fleet and Rancher Fleet; the Homebrew
cask is therefore `fleet-cockpit`, and the npm package is `fleet-cockpit`.

## License

- `plugin/` — MIT
- `bin/`, `hud/`, `gui/`, `app/` — commercial EULA, see [LICENSE.md](LICENSE.md).
  14-day trial, then Free tier or a paid key. 30-day refund.

## Roadmap

- Resume a killed Claude session automatically on relaunch (manual "Resume last chat" exists)
- Attention/HUD for Codex panes (today the HUD is Claude Code only)
- Drag to reorder / resize panes (the grid is equal-split)
- Linux (`systemd-inhibit` + tmux)
- WezTerm / kitty native-split backend
- Team cost dashboard
