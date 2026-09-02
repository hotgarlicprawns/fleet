# fleet

**Many Claude Code terminals, one tiled screen.** Keeps your Mac awake through
long agent runs and blanks the display *without touching your monitor
arrangement* — the thing that matters when your laptop's built-in panel is dead.

```
fleet up            # tiled grid of N `claude` sessions + power management
fleet down          # tear it down, release the awake-lock
fleet status         # pretty dashboard
fleet power awake-blank
fleet config         # interactive wizard
```

## Install

```bash
# CLI
git clone <this repo> && cd fleet && npm link      # or: npm i -g @fleet/cli
brew install tmux                                   # required
brew install displayplacer                          # optional: display profiles

# Claude Code plugin (auto power-management on session start)
/plugin marketplace add ~/Projects/fleet
/plugin install fleet@fleet-marketplace
```

## How it works

| Piece | Tool |
|---|---|
| Tiled terminal grid | `tmux` (mouse on, pane borders labelled) |
| Keep system awake | `caffeinate` with mode-dependent flags |
| Blank the screen | `pmset displaysleepnow` — wakes on keypress, **never** re-arranges displays |
| Display profiles (opt-in) | `displayplacer`, only if `display.manageArrangement: true` |
| License | Dodo Payments `/licenses/activate` + `/licenses/validate`, 7-day offline grace |

### Power modes

| mode | caffeinate | display | use for |
|---|---|---|---|
| `awake-blank` | `-i -s` | blanks (immediately or after `blankAfterMinutes`) | **long runs** — default |
| `awake-on` | `-d -i -s` | stays on | you want to watch |
| `prevent-all` | `-d -i -m -s` | stays on | disk-heavy work |
| `off` | — | — | nothing |

The built-in laptop panel is never singled out or reconfigured — `fleet` only
ever blanks (all) displays or, opt-in, applies a `displayplacer` profile you
saved yourself.

## Config — `~/.config/fleet/config.json`

```jsonc
{
  "session": "fleet",
  "panes": 4,
  "layout": "tiled",              // tiled | even-horizontal | even-vertical | main-vertical
  "command": "claude",           // run in every pane
  "cwd": "~",
  "perPaneCommands": [],          // per-index override, e.g. ["claude", "claude --resume", "btop"]
  "power": { "mode": "awake-blank", "blankAfterMinutes": 0, "releaseOnDetach": true },
  "display": { "manageArrangement": false, "profileOnUp": null, "profileOnDown": null },
  "ui": { "theme": "aurora", "banner": true }   // aurora | mono | nord | solar
}
```

## Pricing (planned)

| | Free | Pro |
|---|---|---|
| Panes | 2 | 16 |
| Power modes | `awake-on`, `off` | all |
| Display profiles | — | ✓ |
| Themes | aurora | all |

`fleet license activate <key>` — keys issued by Dodo Payments. Set
`license.productId` in config to your product.

## Roadmap

- Linux (`systemd-inhibit` + tmux)
- WezTerm / kitty native-split backend
- `fleet watch` — auto-blank after N minutes idle, auto-restore on activity
- Session templates (`fleet up --template review`)
