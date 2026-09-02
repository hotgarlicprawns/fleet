---
description: Open the fleet settings + status panel in a browser
allowed-tools: Bash(fleet:*)
---

```
fleet gui
```

Starts a local panel on `http://127.0.0.1:7787` (bound to localhost only) and opens it.
From there you can: launch/tear down the grid, switch power mode, blank the screen,
install the cost HUD, rename panes, set the budget thresholds, and edit grid defaults —
all writing to `~/.config/fleet/config.json`. Launching from the panel builds the tmux
session in the background; attach from a terminal with `fleet up`.

Runs until you press Ctrl-C. Set a different port with `FLEET_PORT=9000 fleet gui`.
