# fleet-lean

Two Claude Code tools that fuse several built-in tool calls into one, so a
session makes fewer round-trips and spends fewer tokens doing routine
search-and-edit work.

**No account. No cloud. No telemetry that leaves this machine.** It's a local
MCP server (plain Node, stdio) that Claude Code starts as a subprocess. It
works standalone — you do not need the `fleet` CLI, the Fleet app, or a
license of any kind. It is MIT-licensed and free forever; see the root
[LICENSE.md](../LICENSE.md).

This is Fleet's own answer to a class of commercial "token-saving" Claude
Code plugins that require signing up for an external service to see your
savings. fleet-lean's savings numbers are computed and stored entirely under
`~/.config/fleet/` on your machine.

## Install

```
/plugin marketplace add ~/Projects/fleet
/plugin install fleet-lean@fleet-marketplace
```

## Tools

- **`lean_search`** — glob + grep + read, fused into one call, returning
  ranked snippets (matched line ± context) instead of full file contents.
- **`lean_edit`** — batch find/replace across one or more files in one call.
  Matching tolerates reindentation and unicode look-alike punctuation (curly
  vs straight quotes, em/en dash vs hyphen, ellipsis), but if a `find` text
  matches more than one place in a file and you don't say which one
  (`occurrence`), **the edit is rejected and nothing is changed** — it never
  guesses which occurrence you meant. A batch is all-or-nothing: if any edit
  in the call can't be resolved, none of them are applied.

## Savings report

```
/fleet-lean-report
```

Reads the current session's sidecar (`~/.config/fleet/sessions/*.lean.json`)
and estimates tool calls and tokens avoided. Token counts are a `bytes/4`
estimate, not exact — labeled as such. A dollar figure only appears if you've
also run `fleet hud install` (from the main `fleet` CLI), so there's real
cost data to convert against; otherwise it just shows token counts.

## What this is not (yet)

v1 is search + edit only. AST-aware file reading (stub out function bodies,
keep signatures) and post-edit compile/lint validation are deliberately cut
from v1 — see the project's planning notes for why (heuristic parsing is
unreliable enough on some languages, notably Swift's closures and string
interpolation, that shipping it half-working would undercut the whole
promise of "doesn't break things to save tokens"). They're an honest
fast-follow once v1's real, measured savings numbers justify the added
complexity.

## Testing

```
plugin-lean/test/hard-test.sh
```

Real-repo before/after numbers, and a mutation-tested guarantee that the
ambiguity guard actually prevents editing the wrong occurrence (the test is
run once with the guard disabled to confirm it *would* fail without the fix).
