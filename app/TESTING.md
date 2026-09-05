# Hard-testing Fleet.app

Run the whole automated suite yourself any time:

```bash
./hard-test.sh      # ~90s, backs up and restores your real app.json, exits non-zero on any failure
./soak-test.sh &    # long-running RSS/CPU/FD monitor — see its header for how to check it later
```

`hard-test.sh` covers everything below except real UI clicks (needs
Accessibility permission — see the script's section 8 for exactly how to
grant it, then re-run). Last run: **16 passed, 0 failed, 1 skipped**,
reproducible across repeats.

What's been load-tested headlessly (no screen-recording/accessibility
permission in the build environment, so this is process/resource-level, not
visual), what it found, and what you should click through yourself.

## Results so far

| Test | Setup | Result |
|---|---|---|
| Many concurrent panes | 6 screens × 6 panes = 36 real PTYs | 36/36 spawned; ~400MB RSS at startup settling to ~155MB idle; CPU near 0% once idle; 81 FDs held (limit 61,440/process) |
| Sustained run | same 36 panes, watched over several minutes | no memory growth, no crash, all children stayed alive |
| Clean quit | quit the app normally | power assertion released, no orphaned child processes |
| Force-kill (`kill -9`) | killed the app process directly | power assertion auto-released by the kernel (tied to the process, not a shelled-out `caffeinate`); PTY children died with the parent — **no orphans** |
| Repeated launch | 4x cold launch/quit cycles | reliable single window every time (this exposed and fixed a phantom-window bug) |
| Legacy/malformed config | old single-screen format, and a screen missing `id` | migrates / falls back to defaults instead of crashing (this exposed and fixed two decode bugs) |
| Git worktree isolation | 2 screens, 2 branches, real repo | confirmed via each pane's actual `cwd` — genuinely separate working trees |
| Worktree isolation, file-level | 2 worktrees, a real remote (local bare repo) | a file created in worktree A is provably invisible in worktree B and vice versa |
| Sync / Push | real fetch+rebase+push against a real (local) remote | both succeed — the git plumbing itself is sound, independent of the app UI |
| Config corruption | invalid JSON in app.json | falls back to defaults instead of crashing |

## Two real bugs this found (already fixed)

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
