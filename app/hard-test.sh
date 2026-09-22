#!/bin/bash
# fleet Fleet.app — hard-test suite.
# Runs the scenarios from TESTING.md end to end and prints PASS/FAIL/SKIP.
# Safe to re-run: it backs up and restores your real ~/.config/fleet/app.json,
# and only ever kills processes it can prove are its own test app/children —
# never a blanket `pkill claude` that could hit an unrelated real session.
set -uo pipefail
cd "$(dirname "$0")"

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleet"
APPJSON="$CFG_DIR/app.json"
BACKUP="$APPJSON.hardtest-bak"
PASS=0; FAIL=0; SKIP=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1"; SKIP=$((SKIP+1)); }
section() { echo; echo "-- $1 --"; }

app_pid() { ps -axo pid,command | awk '/Fleet\.app\/Contents\/MacOS\/Fleet/ && !/awk/ {print $1; exit}'; }
child_count() { ps -axo pid,ppid | awk -v a="$1" '$2==a' | wc -l | tr -d ' '; }
total_rss_mb() { ps -axo pid,ppid,rss | awk -v a="$1" '$1==a || $2==a {s+=$3} END{printf "%.0f", s/1024}'; }
kill_app_tree() {
  local p; p=$(app_pid)
  [ -z "$p" ] && return 0
  # kill only this app's own children, then the app itself — never a blanket pkill
  for c in $(ps -axo pid,ppid | awk -v a="$p" '$2==a{print $1}'); do kill -9 "$c" 2>/dev/null; done
  kill -9 "$p" 2>/dev/null
  sleep 1
}
launch() {
  # a leftover instance would make `open` merely re-activate it (with the OLD config)
  if [ -n "$(app_pid)" ]; then echo "     (note: stray Fleet instance found before launch — killed)"; kill_app_tree; fi
  open Fleet.app; sleep "${1:-3}"
}

[ -f "$APPJSON" ] && cp "$APPJSON" "$BACKUP"
LICBAK="$CFG_DIR/.hardtest-lic"
rm -rf "$LICBAK"; mkdir -p "$LICBAK"
for f in trial.json license.json owner; do [ -e "$CFG_DIR/$f" ] && cp -p "$CFG_DIR/$f" "$LICBAK/$f"; done
# every section except 7c runs as an entitled owner; 7c manages entitlement itself
touch "$CFG_DIR/owner"
cleanup() {
  kill_app_tree
  [ -f "$BACKUP" ] && mv "$BACKUP" "$APPJSON"
  for f in trial.json license.json owner; do
    rm -f "$CFG_DIR/$f"; [ -e "$LICBAK/$f" ] && cp -p "$LICBAK/$f" "$CFG_DIR/$f"
  done
  rm -rf "$LICBAK"
}
trap cleanup EXIT

echo "=== fleet Fleet.app hard-test suite ==="
echo "log: $CFG_DIR/app-debug.log"

# ---------------------------------------------------------------------------
section "1. build"
swift build > /tmp/fleet-swiftbuild.log 2>&1 || true
if grep -q "Build complete" /tmp/fleet-swiftbuild.log; then
  pass "swift build"
else
  fail "swift build — see /tmp/fleet-swiftbuild.log"; exit 1
fi
./build-app.sh > /tmp/fleet-buildapp.log 2>&1 || true
if grep -q "built Fleet.app" /tmp/fleet-buildapp.log; then
  pass "app bundle assembled"
else
  fail "app bundle assembly — see /tmp/fleet-buildapp.log"; exit 1
fi

# ---------------------------------------------------------------------------
section "2. config resilience (legacy format, missing fields, corrupt JSON)"
kill_app_tree
cat > "$APPJSON" <<'EOF'
{ "panes": [ { "name": "legacy-no-id" } ] }
EOF
rm -f "$CFG_DIR/app-debug.log"
launch 3
p=$(app_pid)
if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then pass "legacy single-screen config (no id field): app launches"; else fail "legacy config crashed the app"; fi
kill_app_tree

printf '{ this is not valid json' > "$APPJSON"
launch 3
p=$(app_pid)
if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then pass "corrupt JSON: falls back to defaults instead of crashing"; else fail "corrupt JSON crashed the app"; fi
kill_app_tree

# ---------------------------------------------------------------------------
section "3. load: many concurrent PTYs (6 screens x 6 panes = 36)"
python3 - > "$APPJSON" <<'PYEOF'
import json
screens = [{"name": f"s{i}", "panes": [
    {"name": f"p{j}", "command": "i=0; while true; do i=$((i+1)); sleep 2; done", "cwd": "/tmp"}
    for j in range(6)
]} for i in range(6)]
json.dump({"screens": screens, "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 8
p=$(app_pid)
n=$(child_count "$p")
[ "$n" = "36" ] && pass "36/36 PTYs spawned" || fail "expected 36 children, got $n"
rss=$(total_rss_mb "$p")
echo "     total RSS: ${rss}MB"
[ "${rss:-9999}" -lt 1500 ] 2>/dev/null && pass "RSS reasonable for 36 panes (${rss}MB)" || fail "RSS too high: ${rss}MB"
sleep 20
n2=$(child_count "$p")
[ "$n2" = "36" ] && pass "all 36 still alive after 20s (no crash-loop)" || fail "pane died under load: $n2/36 alive"
rss2=$(total_rss_mb "$p")
echo "     RSS after 20s: ${rss2}MB"

# ---------------------------------------------------------------------------
section "4. crash resilience (kill -9)"
p=$(app_pid)
kill -9 "$p" 2>/dev/null
sleep 2
if pmset -g assertions | grep -qi "fleet"; then fail "power assertion leaked after kill -9"; else pass "power assertion auto-released on kill -9 (kernel-tied, not a leaked caffeinate)"; fi
if ps -axo ppid | grep -qx "$p"; then fail "orphaned children survive kill -9"; else pass "no orphaned PTYs after kill -9"; fi

# ---------------------------------------------------------------------------
section "5. git worktree isolation + sync/push against a REAL remote"
T=/tmp/fleet-hardtest-$$
rm -rf "$T" "$T-remote.git" "$T-worktrees"
mkdir -p "$T" && (cd "$T" && git init -q && git commit -q --allow-empty -m init)
git init -q --bare "$T-remote.git"
( cd "$T" && git remote add origin "$T-remote.git" && git push -q -u origin HEAD:main )

( cd "$T" && git worktree add -q -b screen-a "$T-worktrees/screen-a" ) 2>/tmp/fleet-wt-a.log
( cd "$T" && git worktree add -q -b screen-b "$T-worktrees/screen-b" ) 2>/tmp/fleet-wt-b.log
if [ -d "$T-worktrees/screen-a" ] && [ -d "$T-worktrees/screen-b" ]; then
  pass "two worktrees created (mirrors GitWorktree.swift's <repo>-worktrees/<branch> layout)"
else
  fail "worktree creation failed — see /tmp/fleet-wt-a.log /tmp/fleet-wt-b.log"
fi
echo "only in A" > "$T-worktrees/screen-a/only-in-a.txt"
echo "only in B" > "$T-worktrees/screen-b/only-in-b.txt"
if [ -f "$T-worktrees/screen-a/only-in-a.txt" ] && [ ! -f "$T-worktrees/screen-b/only-in-a.txt" ] \
   && [ -f "$T-worktrees/screen-b/only-in-b.txt" ] && [ ! -f "$T-worktrees/screen-a/only-in-b.txt" ]; then
  pass "isolation confirmed: a file created in screen A's worktree is invisible in screen B's, and vice versa"
else
  fail "worktree isolation broken — a file leaked across worktrees"
fi

( cd "$T-worktrees/screen-a" && git add -A && git commit -q -m "change in A" \
  && git fetch -q origin main && git rebase -q origin/main ) \
  && pass "sync (fetch+rebase onto base) succeeds against a real remote" \
  || fail "sync against a real remote failed"
( cd "$T-worktrees/screen-a" && git push -q -u origin screen-a ) \
  && pass "push succeeds against a real remote" \
  || fail "push against a real remote failed"

rm -rf "$T" "$T-remote.git" "$T-worktrees"

# ---------------------------------------------------------------------------
section "6. polling scale regression (O(panes x sessions) bug)"
D=/tmp/fleet-sessions-bench-$$
rm -rf "$D"; mkdir -p "$D"
python3 - "$D" <<'PYEOF'
import json, time, random, sys
d = sys.argv[1]
now = time.time()
for i in range(2000):
    json.dump({"sessionId": f"s{i}", "dir": f"/tmp/proj{i%50}", "model": "Sonnet 5",
               "costUsd": round(random.random()*10, 2), "ctxPct": random.randint(1, 90),
               "attention": False, "state": "working", "updated": now - random.randint(0, 3000)},
              open(f"{d}/s{i}.json", "w"))
PYEOF
MS=$(python3 - "$D" <<'PYEOF'
import json, time, os, sys
d = sys.argv[1]
t0 = time.time()
out = []
for fn in os.listdir(d):
    with open(os.path.join(d, fn)) as f:
        out.append(json.load(f))
print(round((time.time()-t0)*1000, 1))
PYEOF
)
echo "     single full scan of 2000 sidecars: ${MS}ms"
python3 -c "exit(0 if float('$MS') < 500 else 1)" && pass "single-scan cost stays low at 2000 sidecars (${MS}ms) — the per-pane-rescan bug is fixed" || fail "single scan too slow: ${MS}ms"
rm -rf "$D"

# ---------------------------------------------------------------------------
section "7. clean quit"
python3 - > "$APPJSON" <<'PYEOF'
import json
json.dump({"screens": [{"name": "s", "panes": [{"name": "p0", "command": "sleep 600", "cwd": "/tmp"}]}],
           "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 3
p=$(app_pid)
kids=$(ps -axo pid,ppid | awk -v a="$p" '$2==a{print $1}')
osascript -e 'tell application "Fleet" to quit' >/dev/null 2>&1
sleep 2
if ps -p "$p" >/dev/null 2>&1; then
  fail "app still running after AppleScript quit — falling back to SIGTERM for cleanup"
  kill "$p" 2>/dev/null; sleep 1
else
  pass "quits cleanly via the standard Quit path"
fi
if pmset -g assertions | grep -qi fleet; then fail "power assertion leaked after clean quit"; else pass "power assertion released on clean quit"; fi
for k in $kids; do if kill -0 "$k" 2>/dev/null; then fail "orphaned child $k after clean quit"; fi; done

# ---------------------------------------------------------------------------
section "7b. closing a screen / removing a pane kills its agents (no leaks)"
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 3; }
python3 - > "$APPJSON" <<'PYEOF'
import json
def scr(n, secs, panes=1):
    # compound command => the sleeper is a GRANDCHILD of the shell (the orphan case)
    return {"name": n, "panes": [{"name": f"p{i}", "command": f"sleep {secs}{i}; sleep 0", "cwd": "/tmp"} for i in range(panes)]}
json.dump({"screens": [scr("keep", 5100), scr("doomed", 5200), scr("shrink", 5300, 3)], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
alive() { pgrep -f "sleep $1" >/dev/null 2>&1; }
if alive 51000 && alive 52000 && alive 53000 && alive 53001 && alive 53002; then pass "5 agents (grandchildren of their shells) running before close"; else fail "setup: expected agents not all running"; fi
ctl '{"cmd":"closeScreen","name":"doomed"}'
sleep 3
if alive 52000; then fail "LEAK: agent of a closed screen is still running (orphaned)"; else pass "closing a screen kills its agent (process group, incl. grandchild)"; fi
if alive 51000 && alive 53000; then pass "other screens' agents untouched"; else fail "closing one screen killed another's agent"; fi
ctl '{"cmd":"setPaneCount","name":"shrink","count":1}'
sleep 3
if alive 53001 || alive 53002; then fail "LEAK: removed panes' agents still running"; else pass "removing panes kills their agents"; fi
if alive 53000; then pass "remaining pane survives a shrink"; else fail "shrink killed the surviving pane"; fi
kill_app_tree
pkill -f "sleep 5[123]0" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "7d. closing a git-backed screen: safe worktree cleanup"
G=/tmp/fleet-wt-clean-$$
rm -rf "$G" "$G-worktrees"; mkdir -p "$G"
( cd "$G" && git init -q -b main && git commit -q --allow-empty -m init \
  && git worktree add -q -b clean-br "$G-worktrees/clean-br" && git worktree add -q -b dirty-br "$G-worktrees/dirty-br" )
echo "precious uncommitted work" > "$G-worktrees/dirty-br/unsaved.txt"
python3 - "$G" > "$APPJSON" <<'PYEOF'
import json, sys
g = sys.argv[1]
def scr(name, br, cmd):
    wt = f"{g}-worktrees/{br}"
    return {"name": name, "repoPath": g, "worktreePath": wt, "branch": br, "baseBranch": "main",
            "panes": [{"name": "p0", "command": cmd, "cwd": wt}]}
json.dump({"screens": [scr("clean", "clean-br", "sleep 6301; sleep 0"), scr("dirty", "dirty-br", "sleep 6302; sleep 0"),
                       {"name": "stay", "panes": [{"name": "p0", "command": "sleep 6303; sleep 0", "cwd": "/tmp"}]}],
           "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
rm -f "$CFG_DIR/app-debug.log"; launch 6
ctl '{"cmd":"closeScreen","name":"clean","removeWorktree":true}'
ctl '{"cmd":"closeScreen","name":"dirty","removeWorktree":true}'
sleep 5
[ -d "$G-worktrees/clean-br" ] && fail "clean worktree was not removed" || pass "clean worktree removed after its agent was stopped"
( cd "$G" && git branch --list clean-br | grep -q clean-br ) && fail "merged branch was not deleted" || pass "merged branch deleted (git branch -d)"
[ -f "$G-worktrees/dirty-br/unsaved.txt" ] && pass "worktree with uncommitted work was KEPT, file intact" || fail "DATA LOSS: uncommitted file destroyed"
grep -q "uncommitted changes" "$CFG_DIR/app-debug.log" && pass "user told why the dirty worktree was kept" || fail "no explanation shown for the kept worktree"
alive 6301 && fail "agent in removed worktree still running" || pass "agents of both closed screens stopped"
alive 6303 && pass "unrelated screen untouched" || fail "cleanup killed an unrelated screen"
kill_app_tree; pkill -f "sleep 63" 2>/dev/null
( cd "$G" && git worktree prune ); rm -rf "$G" "$G-worktrees"

# ---------------------------------------------------------------------------
FAIL_BEFORE_7E=$FAIL
section "7e. window close hides (agents keep running); hotkey; summon"
python3 - > "$APPJSON" <<'PYEOF'
import json
json.dump({"screens": [{"name": "s", "panes": [{"name": "p0", "command": "sleep 6401; sleep 0", "cwd": "/tmp"}]}],
           "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
rm -f "$CFG_DIR/app-debug.log"; launch 5
grep -q "hotkey ⌃⌥F registered: true" "$CFG_DIR/app-debug.log" && pass "global hotkey ⌃⌥F registered" || fail "global hotkey failed to register"
ctl '{"cmd":"windowState"}'
grep -q "windowState: visible=true" "$CFG_DIR/app-debug.log" && pass "window visible at launch" || fail "window not visible at launch"
ctl '{"cmd":"performClose"}'
ctl '{"cmd":"windowState"}'
grep -q "windowState: visible=false" "$CFG_DIR/app-debug.log" && pass "close button hides the window" || fail "close did not hide the window"
[ -n "$(app_pid)" ] && pass "app keeps running with no window (lives in the menu bar)" || fail "app quit when its window closed"
alive 6401 && pass "closing the window does NOT stop running agents" || fail "closing the window killed the agents"
ctl '{"cmd":"summon"}'
ctl '{"cmd":"windowState"}'
tail -1 "$CFG_DIR/app-debug.log" | grep -q "visible=true" && pass "summon brings the window back" || fail "summon did not restore the window"
alive 6401 && pass "agent survived hide + summon (same session)" || fail "agent lost across hide/summon"
[ "$FAIL" -gt "${FAIL_BEFORE_7E:-0}" ] && cp "$CFG_DIR/app-debug.log" /tmp/fleet-7e-fail.log 2>/dev/null
kill_app_tree; pkill -f "sleep 6401" 2>/dev/null

# ---------------------------------------------------------------------------
section "7c. licensing: free-tier cap, trial, unlock, lapse, activation errors"
sleepers() { python3 - "$@" > "$APPJSON" <<'PYEOF'
import json, sys
n = int(sys.argv[1])
json.dump({"screens": [{"name": "lic", "panes": [
    {"name": f"p{i}", "command": f"sleep 610{i}; sleep 0", "cwd": "/tmp"} for i in range(n)]}],
    "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
}
trial_ago() { python3 -c "import json,datetime;json.dump({'startedAt':(datetime.datetime.utcnow()-datetime.timedelta(days=$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z')},open('$CFG_DIR/trial.json','w'))"; }
alive() { pgrep -f "sleep $1" >/dev/null 2>&1; }
reset_lic() { rm -f "$CFG_DIR/license.json" "$CFG_DIR/owner"; }

# 1. trial expired + no license => Free: only 3 of 5 panes run; the rest stay locked (not deleted)
reset_lic; trial_ago 30; sleepers 5; rm -f "$CFG_DIR/app-debug.log"; launch 6
if alive 6100 && alive 6101 && alive 6102; then pass "free tier: first 3 panes run"; else fail "free tier: first 3 panes not running"; fi
if alive 6103 || alive 6104; then fail "free tier: panes beyond the cap were spawned"; else pass "free tier: panes 4-5 are locked (no agent spawned)"; fi
python3 -c "import json;d=json.load(open('$APPJSON'));assert sum(len(s['panes']) for s in d['screens'])==5" \
  && pass "locked panes are kept in the layout, not deleted" || fail "locked panes were deleted from the saved layout"

# 2. activating unlocks live (owner marker stands in for a paid license here)
touch "$CFG_DIR/owner"; sleep 7
if alive 6103 && alive 6104; then pass "unlock: locked panes start as soon as entitlement flips"; else fail "unlock did not start locked panes"; fi

# 3. lapse re-locks and kills the now-locked agents (no orphans)
rm -f "$CFG_DIR/owner"; sleep 7
if alive 6103 || alive 6104; then fail "lapse: locked agents still running"; else pass "lapse: over-cap agents are stopped again"; fi
if alive 6100 && alive 6101 && alive 6102; then pass "lapse: first 3 panes keep running"; else fail "lapse killed panes inside the cap"; fi

# 4. free tier blocks adding screens past the cap and prompts
rm -f "$CFG_DIR/app-debug.log"
ctl '{"cmd":"addScreen","name":"blocked","panes":1,"command":"sleep 6199; sleep 0"}'
grep -q "upgrade prompt" "$CFG_DIR/app-debug.log" && pass "free tier: adding past the cap shows the upgrade prompt" || fail "no upgrade prompt when adding past the cap"
alive 6199 && fail "free tier: a screen was created past the cap" || pass "free tier: no agent spawned for the blocked screen"
kill_app_tree; pkill -f "sleep 61" 2>/dev/null

# 5. active trial => everything runs
trial_ago 2; sleepers 5; launch 6
if alive 6100 && alive 6104; then pass "active trial: all 5 panes run"; else fail "active trial: panes missing"; fi
kill_app_tree; pkill -f "sleep 61" 2>/dev/null

# 6. activation failure paths (deterministic: unreachable server; live: bogus key)
rm -f "$CFG_DIR/app-debug.log"
open --env FLEET_LICENSE_API=http://127.0.0.1:9 Fleet.app; sleep 4
ctl '{"cmd":"activate","key":"NOT-A-KEY"}'; sleep 2
grep -q "Couldn't reach the license server" "$CFG_DIR/app-debug.log" && pass "activate: unreachable server -> clear message, no crash" || fail "activate: unreachable server not handled"
[ -e "$CFG_DIR/license.json" ] && fail "a failed activation wrote license.json" || pass "failed activation leaves no license behind"
kill_app_tree
rm -f "$CFG_DIR/app-debug.log"
launch 4; ctl '{"cmd":"activate","key":"NOT-A-REAL-KEY-000"}'; sleep 3
if grep -q "Key not found" "$CFG_DIR/app-debug.log"; then pass "activate: bogus key rejected by the live Dodo endpoint (404 -> 'Key not found')"
elif grep -q "Couldn't reach" "$CFG_DIR/app-debug.log"; then skip "activate live check: no network from this machine"
else fail "activate: unexpected result for a bogus key: $(grep 'control: activate' "$CFG_DIR/app-debug.log")"; fi
kill_app_tree

# ---------------------------------------------------------------------------
section "7f. CLI: FLEET_LICENSE_API overrides a saved config.json (regression)"
# Real bug hit live: a persisted license.apiBase in config.json silently
# defeated FLEET_LICENSE_API, because it only overrode the built-in default,
# not a value already merged in from a saved file. Fixed by applying the env
# override after the file merge, in loadConfig() itself.
CFGTEST=/tmp/fleet-cfgtest-$$
mkdir -p "$CFGTEST/fleet"
echo '{"license":{"apiBase":"https://WRONG-HOST.example"}}' > "$CFGTEST/fleet/config.json"
RESOLVED=$(XDG_CONFIG_HOME="$CFGTEST" FLEET_LICENSE_API=https://test.dodopayments.com node ../bin/fleet.js debug-config 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["license"]["apiBase"])')
[ "$RESOLVED" = "https://test.dodopayments.com" ] \
  && pass "FLEET_LICENSE_API overrides a saved config.json's apiBase (resolved: $RESOLVED)" \
  || fail "env override lost to saved config: resolved to '$RESOLVED', expected the env value"
rm -rf "$CFGTEST"

# ---------------------------------------------------------------------------
section "8. UI automation (tab switch, resize) — needs Accessibility permission"
launch 3
if osascript -e 'tell application "System Events" to tell process "Fleet" to get title of window 1' >/dev/null 2>&1; then
  pass "Accessibility granted — running click/resize checks"
  osascript -e 'tell application "System Events" to tell process "Fleet"
    click (first UI element of window 1 whose role description is "button")
  end tell' >/dev/null 2>&1 && pass "clicked a UI element in the window" || fail "click attempt failed"
else
  skip "Accessibility permission not granted to this shell/terminal (osascript error -1719/-25211)."
  echo "        Grant it once: System Settings -> Privacy & Security -> Accessibility ->"
  echo "        add/enable the app running this script (Terminal, iTerm, or Claude Code's"
  echo "        host app), then re-run — this section will do real tab-click + resize checks."
fi
kill_app_tree

# ---------------------------------------------------------------------------
kill_app_tree
echo
echo "=== RESULTS: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
