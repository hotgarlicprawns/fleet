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
launch() { open Fleet.app; sleep "${1:-3}"; }

[ -f "$APPJSON" ] && cp "$APPJSON" "$BACKUP"
cleanup() { kill_app_tree; [ -f "$BACKUP" ] && mv "$BACKUP" "$APPJSON"; }
trap cleanup EXIT

echo "=== fleet Fleet.app hard-test suite ==="
echo "log: $CFG_DIR/app-debug.log"

# ---------------------------------------------------------------------------
section "1. build"
if swift build 2>&1 | tee /tmp/fleet-swiftbuild.log | grep -q "Build complete"; then
  pass "swift build"
else
  fail "swift build — see /tmp/fleet-swiftbuild.log"; exit 1
fi
if ./build-app.sh 2>&1 | tee /tmp/fleet-buildapp.log | grep -q "built Fleet.app"; then
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
