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
/plugin marketplace add hotgarlicprawns/fleet
/plugin install fleet-lean@fleet-marketplace
```

## Tools

- **`lean_search`** — glob + grep + read, fused into one call, returning
  ranked snippets (matched line ± context) instead of full file contents.
- **`lean_edit`** — batch find/replace across one or more files in one call.
  Matches **exact text only by default** (after whitespace/reindentation and
  unicode look-alike punctuation normalization — curly vs straight quotes,
  em/en dash vs hyphen, ellipsis). If a `find` text matches more than one
  place in a file and you don't say which one (`occurrence`), **the edit is
  rejected and nothing is changed** — it never guesses. Two edits in the same
  batch that touch overlapping lines are also rejected outright, rather than
  applying and corrupting the region. The whole batch is atomic across every
  file, not just per-match: every file's new content is staged before
  anything is written, and if any file can't be written, nothing is — an
  earlier version could leave a batch half-applied if a later file failed.
  Refuses to touch binary or non-UTF-8 files, and preserves tabs vs. spaces
  and CRLF vs. LF exactly, rather than risking corruption. Approximate
  (fuzzy) matching is **opt-in** per edit (`fuzzy: true`), only runs for find
  text of 24+ characters (a short string tolerating a couple of characters
  of drift is how an earlier version once matched — and silently overwrote —
  the wrong line), and any fuzzy match actually used is always reported back
  in the result, never applied invisibly.

## Savings report

```
/fleet-lean-report
```

Reads the current session's sidecar (`~/.config/fleet/sessions/*.lean.json`)
and estimates tool calls and tokens avoided. Token counts are a `bytes/4`
estimate, not exact — labeled as such. A dollar figure only appears if you've
also run `fleet hud install` (from the main `fleet` CLI), so there's real
cost data to convert against; otherwise it just shows token counts.

`/fleet-lean-report` also prints an **all-time (this machine)** line, from a
small local rollup (`~/.config/fleet/lean-savings.json`) the server updates on
every call — still local-only, still free, no account. It reports "calls
avoided" as an exact count (derived from the tool's own output, not a guess)
and "estimated tokens used by fleet-lean" separately — it does not invent a
single "tokens saved" number, since we never ran the calls it avoided and
don't actually know what they'd have cost.

## fleet-lean Cloud (optional, not live yet)

A subscription add-on is planned for **cross-machine savings sync** — the
above all-time rollup, but synced across every Mac you use fleet-lean on,
plus a small history view. This is the only thing that will ever require
payment or an account here; `lean_search`, `lean_edit`, and the local,
this-machine report stay free forever, per the promise above.

- `plugin-lean/license.js` and `/fleet-lean-license` (activate/validate/
  deactivate) exist and work against Dodo Payments' license endpoints — same
  pattern as the main `fleet` CLI's licensing — but `plugin-lean/product.json`
  has no product configured yet, so activation currently refuses honestly
  rather than pretending to work.
- There is no sync server yet. Until one exists, the fleet-lean Cloud
  subscription has nothing to actually gate — don't buy it expecting a
  dashboard today.

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

Real-repo before/after numbers, a mutation-tested guarantee that the
ambiguity guard actually prevents editing the wrong occurrence (the test is
run once with the guard disabled to confirm it *would* fail without the fix),
and a dedicated regression section (section 10-11) for a set of real
silent-corruption bugs an Opus-model review found and reproduced against
this code on 2026-09-23 — wrong-line fuzzy matches, reverting another
agent's concurrent changes, overlapping-edit corruption, tab/CRLF/non-UTF-8
handling, a glob-parsing hang, and a noisy generated file crowding a real
match out of search results. All were fixed and are now guarded by tests
that reproduce the exact original failure, not just check the fix in the
abstract.
