---
description: Show how many tool calls and tokens fleet-lean's search/edit tools saved this session
argument-hint: ""
allowed-tools: Bash(node:*)
---

Run: `node ${CLAUDE_PLUGIN_ROOT}/report.js`

Show its output verbatim — every number in it (calls made, calls avoided, tokens
used, tokens avoided, the all-time rollup) is computed in the script itself, not
by you reading the sidecar JSON and doing the arithmetic yourself. An earlier
version of this command asked the model to sum the numbers by hand; a review
found that produced inconsistent totals across runs, so the computation now
lives in code (`plugin-lean/report.js`) precisely so it can't drift.

Do not recompute, re-derive, round differently, or add a dollar estimate on top
of what the script prints — if it says there's no dollar figure available, say
that, don't invent one. If the script's output mentions a fallback (no sidecar
matched this session), pass that caveat along plainly rather than presenting
the numbers as certainly this session's own.

If `node ${CLAUDE_PLUGIN_ROOT}/license.js validate` (see `/fleet-lean-license`)
reports an active fleet-lean Cloud subscription, mention that synced
cross-machine history will appear here once the cloud sync endpoint ships (it
does not exist yet — say so plainly, don't imply a dashboard exists today).
