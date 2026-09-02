---
description: Drive the fleet CLI — tiled terminals, power, cost HUD
argument-hint: "[up|resume|down|status|next|name <i> <name>|report|power <mode>|watch|hud install|config|tune]"
allowed-tools: Bash(fleet:*)
---

Run the `fleet` CLI with the user's arguments and report the result.

Arguments: `$ARGUMENTS` (default to `status` if empty)

```
fleet $ARGUMENTS
```

Notes:
- `fleet up [template]` builds a tmux session of tiled panes (config-driven names/dirs/accents), each running `claude`, and starts power management so the Mac stays awake.
- `fleet next` jumps to the next session waiting for input; `fleet name 2 hotfix` renames a pane on its border.
- `fleet hud install` turns on the per-pane cost + context readout; `fleet report` totals spend by project.
- `fleet power awake-blank` keeps the system awake while letting the display blank — never touches the monitor arrangement (matters on laptops with a dead built-in panel).
- `fleet watch` keeps awake, auto-blanks when idle, and un-blanks when a session needs you.
- Config: `~/.config/fleet/config.json`. If the CLI is missing, run `npm link` in the fleet project or `npm i -g @fleet/cli`.
