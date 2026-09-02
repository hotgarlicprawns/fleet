---
description: Edit fleet settings (panes, layout, power mode, theme) conversationally
allowed-tools: Bash(fleet:*), Read, Edit
---

Open `~/.config/fleet/config.json` and help the user change settings.

1. Read the current config (create it from defaults by running `fleet status` once if missing).
2. Ask what they want to change, or apply what they already asked for.
3. Edit the JSON directly. Keys:
   - `panes` (1–16), `layout` (`tiled|even-horizontal|even-vertical|main-vertical`)
   - `command` (per-pane command, default `claude`), `cwd`, `perPaneCommands` (array)
   - `power.mode` (`awake-blank|awake-on|prevent-all|off`), `power.blankAfterMinutes`
   - `display.manageArrangement` (keep **false** unless the user insists — it can disturb monitor layout)
   - `ui.theme` (`aurora|mono|nord|solar`)
4. Confirm by running `fleet status`.
