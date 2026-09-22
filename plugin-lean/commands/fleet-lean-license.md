---
description: Activate, check, or deactivate a fleet-lean Cloud subscription (optional — the core tools are free forever without this)
argument-hint: "activate <key> | validate | deactivate"
allowed-tools: Bash(node:*)
---

fleet-lean Cloud is an **optional** paid add-on for cross-machine savings sync — `lean_search`
and `lean_edit` themselves are free forever and never check this. See plugin-lean/README.md.

Run: `node ${CLAUDE_PLUGIN_ROOT}/license.js $ARGUMENTS`

- `activate <key>` — activate a fleet-lean Cloud license key on this machine.
- `validate` — check the current license's status with Dodo (falls back to a 7-day offline grace if unreachable).
- `deactivate` — free this machine's seat.

If the command reports that fleet-lean Cloud "is not live yet," that means `plugin-lean/product.json`
has no `apiBase` configured — the subscription product doesn't exist yet. Report that plainly; don't
imply the feature is broken.
