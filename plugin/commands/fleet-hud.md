---
description: Turn on the cost + context HUD, or show what it's tracking
argument-hint: "[install|status|uninstall]"
allowed-tools: Bash(fleet:*)
---

```
fleet hud $ARGUMENTS
```

- `fleet hud install` — writes a statusLine into `~/.claude/settings.json` that renders
  model · context% · cost and also records a JSON sidecar per session under
  `~/.config/fleet/sessions/`. Any existing statusLine is saved and restored on uninstall.
- `fleet hud status` — lists tracked sessions with model, cost, context.
- After install, every fleet pane border shows live `name · model · $cost · ctx%`,
  amber past the budget warn threshold, red past the cap. `fleet report` totals the spend.
