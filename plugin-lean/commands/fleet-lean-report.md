---
description: Show how many tool calls and tokens fleet-lean's search/edit tools saved this session
argument-hint: ""
allowed-tools: Read, Bash(ls:*)
---

Report savings from the `fleet-lean` MCP server for the current session.

1. List `~/.config/fleet/sessions/*.lean.json`, sorted by modification time, and read the
   **most recently modified** one — that is this session's sidecar (the server writes it on
   every `lean_search`/`lean_edit` call; there is no reliable way to correlate the server's
   own run id with Claude Code's session id, so recency is the signal).
2. Sum `estInputTokens` + `estOutputTokens` across every call in its `calls` array. These are
   `bytes / 4` estimates, not exact BPE token counts — say so plainly, don't present them as
   billed tokens.
3. Compute what the equivalent vanilla-tool sequence would likely have cost:
   - each `lean_search` call replaces roughly `1 (Glob) + 1 (Grep) + filesMatched (Read)` calls
   - each `lean_edit` call replaces roughly `2 × edits.length` calls (a Read then an Edit per edit)
4. Also look for `~/.config/fleet/sessions/<same-timeframe>.json` (the fleet HUD's own sidecar,
   written by `hud/statusline.sh` if `fleet hud install` has been run) with a close `updated`
   timestamp. If one exists, use its `costUsd` and this session's total token count (input+output,
   from the HUD's own numbers if present) to derive a **$ per estimated token** ratio, and multiply
   that by the tokens saved here for a dollar estimate. If no HUD sidecar is found, skip the dollar
   figure entirely and say: "install the HUD (`fleet hud install`) for a cost estimate" — never
   invent a $ figure without real cost data behind it.
5. Print a short summary: tool calls made via fleet-lean, estimated built-in-tool calls avoided,
   estimated tokens saved, and the $ estimate if available (labeled as an estimate either way).
