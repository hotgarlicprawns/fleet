---
description: Build/attach the tiled fleet of Claude Code terminals
argument-hint: "[up|down|status|power <mode>|config|blank]"
allowed-tools: Bash(fleet:*)
---

Run the `fleet` CLI with the user's arguments and report the result.

Arguments: `$ARGUMENTS` (default to `status` if empty)

```
fleet $ARGUMENTS
```

Notes:
- `fleet up` creates a tmux session with N tiled panes (config-driven), each running `claude`, and starts power management so the Mac stays awake during long sessions.
- `fleet power awake-blank` keeps the system awake while letting the display blank — it never changes the monitor arrangement, which matters on laptops with a dead built-in panel.
- Config lives at `~/.config/fleet/config.json`; `fleet config` is an interactive wizard.
If the CLI is not installed, tell the user to run `npm link` in the fleet project or `npm i -g @fleet/cli`.
