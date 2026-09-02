# fleet

**Many Claude Code terminals, one tiled screen** — with the cost and context of
every session on its pane border, a machine that stays awake through long runs,
and a screen that blanks *without touching your monitor arrangement* (the thing
that matters when your laptop's built-in panel is dead).

```
fleet up             # tiled grid of `claude` sessions + power management + HUD
fleet next           # jump to the session that's waiting for you
fleet report         # spend, grouped by project
fleet watch          # stay awake, blank when idle, wake when a session needs you
fleet down           # tear it all down
```

## Install

```bash
git clone <repo> && cd fleet && npm link      # or: npm i -g @fleet/cli
brew install tmux                              # required
brew install jq                                # optional — faster HUD
brew install displayplacer                     # optional — display profiles

fleet hud install    # wire the cost + context HUD into Claude Code
fleet gui            # settings + status panel in your browser
fleet config         # …or configure from the terminal
fleet up
```

## GUI

`fleet gui` opens a local control panel (`127.0.0.1:7787`, localhost-only, no
dependencies) to launch/tear down the grid, switch power mode, blank the
screen, install the HUD, rename panes, and set budget thresholds — writing the
same `~/.config/fleet/config.json`. It's also the panel a future menubar app
wraps.

Claude Code plugin (auto power-management + attention flags per session):

```
/plugin marketplace add ~/Projects/fleet
/plugin install fleet@fleet-marketplace
```

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

## Pricing

14-day full trial, no card. Then:

| | Free | Pro — one-time |
|---|---|---|
| Panes | 3 | 16 |
| Power | `awake-on`, `off` | all + `fleet watch` |
| HUD + `fleet report` | ✓ | ✓ |
| Templates, display profiles | — | ✓ |
| Themes | aurora | all |

```
fleet buy                        # checkout link
fleet license activate <key>     # public Dodo Payments endpoints, 7-day offline grace
fleet license deactivate         # free the seat when switching machines
```

## Distribution

- **now** — `npm i -g @fleet/cli` + a Homebrew tap. Zero signing cost, the
  install path devs expect, instant updates. Paid via license key.
- **later** — a signed, notarized `.dmg` menubar app that bundles the CLI and
  wraps `fleet gui` in a native shell. Build it once the CLI has paying users.

## License

- `plugin/` — MIT
- `bin/`, `hud/`, `gui/` — commercial EULA, see [LICENSE.md](LICENSE.md).
  14-day trial, then Free tier or a paid key. 30-day refund.

## Roadmap

- Menubar `.dmg` app around `fleet gui`
- Global summon hotkey (skhd recipe today)
- Linux (`systemd-inhibit` + tmux)
- WezTerm / kitty native-split backend
- Team cost dashboard
