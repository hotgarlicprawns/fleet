# Hard-testing Fleet.app

Run the whole automated suite yourself any time:

```bash
./hard-test.sh          # ~12 min. Runs in an isolated temp config dir + its own app
                        # instance (open -n --env XDG_CONFIG_HOME=...) — never reads or
                        # writes your real ~/.config/fleet.
./soak-test.sh &        # separate instance + config; see its header. `./soak-test.sh stop` ends it.
```

Last full run: **65 passed, 0 failed, 1 skipped** (the skip is real UI automation, which
needs Accessibility permission). The suite runs as an entitled "owner" except section 7c,
which manages entitlement itself; it can't click, so it drives the app through a small
control file (`$XDG_CONFIG_HOME/fleet/control.json`) — including a `dumpState` command that
writes the toolbar's rollups (account rate limits, fleet-lean savings) to a file for
assertions the UI-automation section can't reach without Accessibility permission.

Sections: 1 build · 2 config resilience · 3 load (36 idle PTYs) · 3b load (36 panes under
**sustained heavy continuous output**, not idle — this is the "many terminals actually
working" scenario, added 2026-09-23 because the original section 3 only proved idle panes
don't crash) · 3c pane-grid identity (growing/shrinking pane count must not kill an
*untouched* pane's agent — a real bug this found) · 3d per-pane close removes the chosen
pane, not always the last one · 3e closing to zero screens actually persists as zero ·
3f top-bar rollups (account-grouped rate limits, real fleet-lean savings, via `dumpState`)
· 3g auto-naming from a real terminal-title escape sequence, and that a manually-named pane
is never overwritten · 3h multi-account: a pane switched to an extra account really restarts
with that account's `CLAUDE_CONFIG_DIR`/`FLEET_ACCOUNT` (read from the process's actual
environment), while a default-account pane is left running untouched · 3i focused-pane
tracking: a real AppKit first-responder change is detected and Close Focused Pane
(⌘⇧W) closes that actual pane, not always the last one · 4 kill -9 · 5 git worktrees + real remote · 6 polling scale ·
7 clean quit · 7b close/shrink kills agents · 7d safe worktree cleanup ·
7e window hide/summon/hotkey · 7c licensing (12 checks incl. live Dodo endpoint) · 8 UI.

**Known unexplained flake:** in one full run, 7e failed four checks (no visible window, pane
never spawned) and then passed on every rerun — alone, after 7d, and in two more full runs,
plus 12/12 clean back-to-back launches. Suspected cause: SwiftUI occasionally not opening the
main window at launch. A self-heal now opens it explicitly (and logs "main window missing after
launch"); it has never fired in testing, so the root cause is unconfirmed. If 7e ever fails
again, `/tmp/fleet-7e-fail.log` holds the app log.

## Results so far

| Test | Setup | Result |
|---|---|---|
| Agents die with their screen | 3 screens, compound command so the agent is a *grandchild* of its shell | closing a screen and removing panes kill the whole process group; mutation-tested (disabling the fix fails both checks) |
| Licensing | trial expired / active / owner, over-cap panes, bogus keys | free cap locks panes without deleting them; unlock/lapse flip live; blocked adds prompt; unreachable server and a bogus key against the live Dodo endpoint both handled |
| Worktree cleanup | clean + dirty worktree, agent inside | clean one removed after its agent stopped; the one with uncommitted work is kept, file intact |
| Many concurrent panes | 6 screens × 6 panes = 36 real PTYs, idle (`sleep` loop, no output) | 36/36 spawned; ~400MB RSS at startup settling to ~155MB idle; CPU near 0% once idle; 81 FDs held (limit 61,440/process) |
| Sustained run | same 36 idle panes, watched over several minutes | no memory growth, no crash, all children stayed alive |
| **Panes actually working** (not idle) | 36 real PTYs, each streaming continuous heavy text output (`yes` printing ~200-byte lines as fast as possible — more output/sec than a real Claude Code session) for 60s | RSS 364MB → 359MB → 357MB over 60s (**flat, not growing** — SwiftTerm's default 500-line scrollback cap holds even under sustained heavy output); all 36 panes still alive |
| Clean quit | quit the app normally | power assertion released, no orphaned child processes |
| Force-kill (`kill -9`) | killed the app process directly | power assertion auto-released by the kernel (tied to the process, not a shelled-out `caffeinate`); PTY children died with the parent — **no orphans** |
| Repeated launch | 4x cold launch/quit cycles | reliable single window every time (this exposed and fixed a phantom-window bug) |
| Legacy/malformed config | old single-screen format, and a screen missing `id` | migrates / falls back to defaults instead of crashing (this exposed and fixed two decode bugs) |
| Git worktree isolation | 2 screens, 2 branches, real repo | confirmed via each pane's actual `cwd` — genuinely separate working trees |
| Worktree isolation, file-level | 2 worktrees, a real remote (local bare repo) | a file created in worktree A is provably invisible in worktree B and vice versa |
| Sync / Push | real fetch+rebase+push against a real (local) remote | both succeed — the git plumbing itself is sound, independent of the app UI |
| Config corruption | invalid JSON in app.json | falls back to defaults instead of crashing |

## Real bugs this found (already fixed)

1. **O(panes × sessions) polling.** The cost/context HUD lookup re-scanned
   the whole `~/.config/fleet/sessions/` folder once *per pane* every 3s.
   Benchmarked against 2,000 sidecar files (realistic after months of use):
   the old code took **~3 seconds of I/O per poll at 48 panes** — it would
   have frozen the UI. Fixed to scan once per cycle, off the main thread:
   flat ~60ms regardless of pane count. Sidecars older than 30 days are now
   also pruned automatically so the folder doesn't grow forever.
2. **`exec` on arbitrary commands.** Panes ran `exec <command>`, which only
   parses a *single simple command* — anything with `;`, `&&`, `|`, or an
   env assignment (`npm i && npm run dev`, a one-liner test command) failed
   silently with exit 127. Fixed by dropping the `exec` and running the
   command as the shell's last statement instead, which handles any shape.
3. **P0: changing pane count could silently kill a DIFFERENT pane's agent.**
   The pane grid nested a VStack/HStack ForEach keyed by row *offset*,
   recomputed from pane count (columns = ceil(√n)). Growing or shrinking a
   screen's pane count changes the column count, moving panes between rows
   — SwiftUI saw a moved pane as leaving one HStack and appearing in a
   different one, tore down its TerminalPane, and killed that pane's whole
   process group. Fixed with a flat `Layout` keyed by `pane.id` — see
   section 3c.
4. **The real `~/.config/fleet/app.json` had a leftover test fixture in
   it** (screen "s", three permanently-sleeping panes) — the earlier
   version of this suite backed up and restored `app.json` in place rather
   than using an isolated config, and an interrupted run left the fixture
   behind. That screen swallowed every keystroke forever — exactly what a
   "dead, unwritable screen" bug report looks like. This suite now runs
   fully isolated (see the `hard-test.sh` header above) so this can't
   happen again.
5. **Two more causes of the same "dead screen" symptom**: nothing set
   keyboard focus at launch, and switching screens only ever toggled
   `activeScreenID` (visibility) without ever moving AppKit's first
   responder — so keystrokes kept going to the previous, now-invisible
   screen. Both fixed; see `CockpitStore.select(_:)`.
6. **The screen close button was invisible whenever you had only one
   screen** (`hover && screens.count > 1`), with no explanation — read
   as "the close button doesn't work." And the ONLY pane-removal control
   was a stepper that always dropped whichever pane was *last*, never the
   one you were looking at. Both fixed: the screen close button always
   shows now, and each pane has its own close button (section 3d).
7. **5h/7d rate limits showed "0%" on a brand-new pane** that simply hadn't
   reported yet, indistinguishable from "genuinely 0% used" — and sidecars
   were matched to panes by directory, so two panes in the same folder
   always showed identical numbers and a new pane could inherit a stale
   reading from an unrelated session. Fixed: missing fields are now `null`,
   not `0`, and matching is by a real per-pane id (`FLEET_PANE_ID`) instead
   of directory.
8. **"Remove Last Pane" (⌘⇧W) always removed whichever pane was literally
   last**, never the one you were looking at, because Fleet never tracked
   which pane actually had keyboard focus. Fixed with `checkFocusedPane()`
   — reads AppKit's real first responder off the fleet window (looked up by
   title, not `NSApp.keyWindow`, which is nil whenever Fleet isn't the
   OS-level frontmost app — the exact case a headless test runs in, and the
   bug that made this fix's own first version of section 3i fail before the
   real cause was found) — and closes that pane via `closeFocusedPane`,
   the same method the menu command now calls.

## What you should test by hand (needs real clicking)

- **Rapid tab switching** while panes are mid-output — watch for dropped
  keystrokes or a pane that stops repainting.
- **Resize the window** with 8–16 panes visible — check the grid re-tiles
  without a pane collapsing to zero size.
- **Actually disconnect a display** (unplug the external, or on the office
  laptop, whatever triggers the dead-panel state) while a screen is pinned
  to it — confirm the window jumps to the remaining display instead of
  vanishing.
- **Run 2 real `claude` sessions in 2 screens on 2 branches of the same
  repo simultaneously**, have them both touch files, then Sync one — the
  git plumbing and filesystem isolation are proven (see above); what's left
  untested is live model output in that setup, which needs a real prompt.

`hard-test.sh`'s section 8 will run tab-click/resize checks automatically
once you grant Accessibility permission to the terminal running it — see
that section's output for the exact steps.

## How to push further yourself

```bash
# generate an N-screen x M-pane synthetic config and watch resource use
python3 - <<'EOF' > ~/.config/fleet/app.json
import json
N, M = 10, 8   # adjust
screens = [{"name": f"s{i}", "panes": [
    {"name": f"p{j}", "command": "i=0; while true; do i=$((i+1)); echo tick $i; sleep 2; done", "cwd": "/tmp"}
    for j in range(M)
]} for i in range(N)]
json.dump({"screens": screens, "power": "Display on"}, open("/dev/stdout","w"))
EOF
open Fleet.app
# then, repeatedly:
ps -axo pid,ppid,rss,%cpu,command | grep -A999 Fleet | awk '{s+=$3} END{print s/1024" MB"}'
```
