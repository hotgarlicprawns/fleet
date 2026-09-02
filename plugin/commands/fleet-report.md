---
description: Show Claude Code spend grouped by project
argument-hint: "[week|all]"
allowed-tools: Bash(fleet:*)
---

```
fleet report $ARGUMENTS
```

Aggregates the per-session cost sidecars written by the HUD (`fleet hud install` first).
Default window is the last 24h; `week` = 7 days; `all` = everything on record.
Flags any day over `budget.dailyUsd` in `~/.config/fleet/config.json`.
