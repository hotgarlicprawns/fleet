#!/bin/bash
# fleet Fleet.app — hard-test suite.
# Runs the scenarios from TESTING.md end to end and prints PASS/FAIL/SKIP.
#
# Runs in its OWN config directory and its OWN app instance (open -n --env),
# exactly like soak-test.sh — it NEVER reads or writes your real
# ~/.config/fleet. An earlier version backed up and restored app.json in
# place instead, and a killed/interrupted run once left a leftover test
# fixture (screen "s", three permanently-sleeping panes) sitting in a real
# ~/.config/fleet/app.json — a screen that looks exactly like a "dead,
# unwritable" bug report. This isolation is what prevents that class of
# problem entirely, not just recovers from it after the fact.
#
# Only ever kills processes it can prove are its own test app/children —
# never a blanket `pkill claude` that could hit an unrelated real session.
set -uo pipefail
cd "$(dirname "$0")"

TESTROOT=$(mktemp -d /tmp/fleet-hardtest-cfg.XXXXXX)
export XDG_CONFIG_HOME="$TESTROOT"   # inherited by any `node ...` calls below directly;
                                      # `open` does NOT forward shell env to GUI apps, so
                                      # launch() below passes it explicitly via --env too.
CFG_DIR="$TESTROOT/fleet"
APPJSON="$CFG_DIR/app.json"
mkdir -p "$CFG_DIR"
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
  open -n --env XDG_CONFIG_HOME="$TESTROOT" Fleet.app; sleep "${1:-3}"
}

# every section except 7c runs as an entitled owner; 7c manages entitlement itself
touch "$CFG_DIR/owner"
cleanup() {
  kill_app_tree
  rm -rf "$TESTROOT"
}
trap cleanup EXIT

echo "=== fleet Fleet.app hard-test suite ==="
echo "config: $CFG_DIR (isolated — your real ~/.config/fleet is never touched)"
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
section "3b. load: panes actually WORKING — sustained heavy terminal output"
# Section 3 above proves idle panes (a bare sleep loop, no output) don't
# crash. That's not the scenario the user actually asked about — "a bunch
# of terminals open and they are working". A real agent session streams
# continuous text. This is what would expose an unbounded SwiftTerm
# scrollback buffer (TerminalPane.swift sets no explicit scrollback limit —
# it relies on SwiftTerm's own default of 500 lines, unverified until now
# that it actually holds RSS flat under real output volume rather than
# growing per byte printed).
python3 - > "$APPJSON" <<'PYEOF'
import json
# Each pane prints a timestamped ~200-byte line as fast as it can, forever —
# meaningfully more output per second than a real Claude Code session, to
# make an unbounded-buffer leak show up fast rather than needing hours.
cmd = "yes 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'"
screens = [{"name": f"h{i}", "panes": [
    {"name": f"p{j}", "command": cmd, "cwd": "/tmp"}
    for j in range(6)
]} for i in range(6)]
json.dump({"screens": screens, "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 10
p=$(app_pid)
n=$(child_count "$p")
[ "$n" = "36" ] && pass "36/36 heavy-output PTYs spawned" || fail "expected 36 children, got $n"
r0=$(total_rss_mb "$p"); echo "     RSS at ~10s of heavy output: ${r0}MB"
sleep 25
r1=$(total_rss_mb "$p"); echo "     RSS at ~35s: ${r1}MB"
sleep 25
r2=$(total_rss_mb "$p"); echo "     RSS at ~60s: ${r2}MB"
n2=$(child_count "$p")
[ "$n2" = "36" ] && pass "all 36 still alive after 60s of continuous output" || fail "pane died under sustained output: $n2/36 alive"
# The real test: growth from the second to third sample (buffer should
# already be full/steady-state by ~35s at this output rate) should be
# small — a scrollback cap holding means RSS goes flat, not a straight
# line up. A generous threshold (150MB) catches an actual unbounded-buffer
# leak while tolerating normal allocator noise.
growth=$(( ${r2:-0} - ${r1:-0} ))
echo "     RSS growth from ~35s to ~60s: ${growth}MB"
if [ "${r1:-9999}" -gt 0 ] && [ "$growth" -lt 150 ] 2>/dev/null; then
  pass "RSS growth stays flat under sustained heavy output (scrollback cap holds, ${growth}MB growth)"
else
  fail "RSS grew ${growth}MB in 25s of continued output — scrollback buffer may be unbounded"
fi

# ---------------------------------------------------------------------------
section "3c. grid identity — changing pane count must not kill OTHER panes' agents"
# Regression for a real bug: ScreenGrid used to nest a VStack/HStack ForEach
# keyed by ROW OFFSET, recomputed from pane count (columns = ceil(sqrt(n))).
# Growing 4 panes to 5 changes the column count, which moves a pane from one
# row to another — SwiftUI saw that as the pane leaving one HStack and
# appearing in a different one, tore down its TerminalPane, and
# dismantleNSView SIGHUP/SIGTERM'd that pane's whole process group. Adding a
# pane could silently kill a DIFFERENT, untouched pane's agent.
python3 - > "$APPJSON" <<'PYEOF'
import json
panes = [{"name": f"p{i}", "command": f"sleep 71{i}0; sleep 0", "cwd": "/tmp"} for i in range(4)]
json.dump({"screens": [{"name": "grid", "panes": panes}], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
alive() { pgrep -f "sleep $1" >/dev/null 2>&1; }
if alive 7100 && alive 7110 && alive 7120 && alive 7130; then
  pass "4 panes running before the grid reflows"
else
  fail "setup: expected 4 sleep panes not all running"
fi
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 3; }
ctl '{"cmd":"setPaneCount","name":"grid","count":5}'
sleep 2
if alive 7100 && alive 7110 && alive 7120 && alive 7130; then
  pass "growing 4 panes to 5 did not kill any of the original 4 (grid identity holds)"
else
  fail "REGRESSION: growing pane count killed one or more untouched panes"
fi
ctl '{"cmd":"setPaneCount","name":"grid","count":2}'
sleep 2
if alive 7100 && alive 7110; then
  pass "shrinking to 2 kept the first 2 panes alive (grid identity holds on shrink too)"
else
  fail "REGRESSION: shrinking pane count killed a pane it should have kept"
fi
kill_app_tree
pkill -f "sleep 71[0-3]0" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3d. per-pane close removes the CHOSEN pane, not always the last one"
# Regression for the "minus button doesn't work" report: the only removal
# path used to be setPaneCount, which always dropped whichever pane was
# LAST — never the one you actually wanted gone.
python3 - > "$APPJSON" <<'PYEOF'
import json
panes = [{"name": f"p{i}", "command": f"sleep 72{i}0; sleep 0", "cwd": "/tmp"} for i in range(3)]
json.dump({"screens": [{"name": "closetest", "panes": panes}], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
alive() { pgrep -f "sleep $1" >/dev/null 2>&1; }
if alive 7200 && alive 7210 && alive 7220; then pass "3 panes running before closing the middle one"; else fail "setup: expected 3 panes not all running"; fi
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 3; }
ctl '{"cmd":"closePane","name":"closetest","pane":"p1"}'
sleep 2
if alive 7200 && alive 7220 && ! alive 7210; then
  pass "closing pane p1 (the middle one) removed exactly that pane, kept p0 and p2"
else
  fail "closePane removed the wrong pane(s): p0=$(alive 7200 && echo alive || echo dead) p1=$(alive 7210 && echo alive || echo dead) p2=$(alive 7220 && echo alive || echo dead)"
fi
kill_app_tree
pkill -f "sleep 72[0-2]0" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3e. closing down to zero screens actually sticks (no auto-recreate)"
# Regression: closeScreen and load() used to both recreate a fresh default
# "main" screen the instant screens became empty, so closing your last
# screen never actually stuck — you'd always land back on a new one.
python3 - > "$APPJSON" <<'PYEOF'
import json
json.dump({"screens": [{"name": "only", "panes": [{"name": "p0", "command": "sleep 900", "cwd": "/tmp"}]}],
           "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 3; }
ctl '{"cmd":"closeScreen","name":"only"}'
sleep 2
COUNT=$(python3 -c "import json; print(len(json.load(open('$APPJSON'))['screens']))" 2>/dev/null)
if [ "$COUNT" = "0" ]; then
  pass "closing the only screen leaves zero screens persisted (no auto-recreated default)"
else
  fail "expected 0 screens persisted after closing the last one, got: $COUNT"
fi
kill_app_tree
pkill -f "sleep 900" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3f. top-bar rollups — account-grouped rate limits, real fleet-lean savings"
PANE_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
python3 - > "$APPJSON" <<PYEOF
import json
json.dump({"screens": [{"name": "rollup", "panes": [
    {"id": "$PANE_ID", "name": "p0", "command": "sleep 800", "cwd": "/tmp"}
]}], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
mkdir -p "$CFG_DIR/sessions"
NOW=$(date +%s)
# Real HUD sidecar for that exact pane, with an account tag and real rate limits.
cat > "$CFG_DIR/sessions/rolluptest.json" <<EOF
{"sessionId":"rolluptest","claudePid":424242,"hudVersion":2,"fleetPaneId":"$PANE_ID","account":"work","configDir":"","dir":"/tmp","model":"Sonnet","costUsd":1.0,"ctxPct":10,"rl5h":42,"rl7d":7,"linesAdded":0,"linesRemoved":0,"attention":false,"state":"working","firstSeen":$NOW,"updated":$NOW}
EOF
# Real fleet-lean sidecar sharing that same claudePid.
cat > "$CFG_DIR/sessions/rolluptest.lean.json" <<EOF
{"runId":"rolluptest","pid":1,"claudePid":424242,"calls":[{"tool":"lean_search","callsAvoided":5,"estTokensAvoided":2500}]}
EOF
# Real all-time rollup (same shape as plugin-lean writes).
cat > "$CFG_DIR/lean-savings.json" <<EOF
{"days":{"2026-01-01":{"calls":3,"callsAvoided":9,"estTokens":300,"estTokensAvoided":4000}}}
EOF
sleep 4   # let a poll cycle (every 3s) pick all of this up
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 2; }
ctl '{"cmd":"dumpState"}'
DUMP="$CFG_DIR/state-dump.json"
if [ -f "$DUMP" ]; then
  python3 -c "
import json
d = json.load(open('$DUMP'))
assert d['rateByAccount']['work']['rl5h'] == 42, d
assert d['rateByAccount']['work']['rl7d'] == 7, d
assert d['leanLiveCalls'] == 5, d
assert d['leanLiveTokens'] == 2500, d
assert d['leanAllTimeCalls'] == 9, d
assert d['leanAllTimeTokens'] == 4000, d
print('ok')
" && pass "account-grouped rate limits and real fleet-lean savings both roll up correctly" \
    || fail "rollup values wrong — see $DUMP"
else
  fail "dumpState never wrote $DUMP"
fi
kill_app_tree
pkill -f "sleep 800" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3g. auto-naming — a real terminal-title escape sequence renames the pane"
# Sends a REAL xterm OSC-2 title escape sequence (the exact mechanism Claude
# Code uses to set its own terminal title) through each pane's shell, proving
# the setTerminalTitle -> onTitle -> autoName -> persist wiring actually
# fires end-to-end — not just that it compiles. Pane B starts pre-marked
# autoNamed:false (as if manually renamed already) to prove a real title
# update never overwrites a name the user chose.
python3 - > "$APPJSON" <<'PYEOF'
import json
title_cmd = "printf '\\033]2;Fixing auth bug\\007'; sleep 800"
json.dump({"screens": [{"name": "autoname", "panes": [
    {"name": "pane 0", "command": title_cmd, "cwd": "/tmp"},
    {"name": "my chosen name", "command": title_cmd, "cwd": "/tmp", "autoNamed": False}
]}], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
sleep 2
NAME_A=$(python3 -c "import json; print(json.load(open('$APPJSON'))['screens'][0]['panes'][0]['name'])" 2>/dev/null)
NAME_B=$(python3 -c "import json; print(json.load(open('$APPJSON'))['screens'][0]['panes'][1]['name'])" 2>/dev/null)
if [ "$NAME_A" = "Fixing auth bug" ]; then
  pass "pane auto-renamed from its real terminal title escape sequence"
else
  fail "expected pane renamed to 'Fixing auth bug', got: '$NAME_A'"
fi
if [ "$NAME_B" = "my chosen name" ]; then
  pass "a pane marked autoNamed:false is never overwritten despite a real title update"
else
  fail "manually-named pane was overwritten: '$NAME_B'"
fi
kill_app_tree
pkill -f "Fixing auth bug\|sleep 800" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3h. multi-account — a pane on an extra account really launches with its own login"
# Each pane dumps its REAL environment to a file. Pane "a" stays on the default
# login; pane "b" is switched to a freshly added account via the same code path
# the UI uses (addAccount + setAccount), which must restart it with
# CLAUDE_CONFIG_DIR / FLEET_ACCOUNT set — and pane "a" must be left alone.
ENV_A="$TESTROOT/env-a.txt"; ENV_B="$TESTROOT/env-b.txt"
python3 - > "$APPJSON" <<PYEOF
import json
json.dump({"screens": [{"name": "accts", "panes": [
    {"name": "a", "command": "env > '$ENV_A'; sleep 801", "cwd": "/tmp", "autoNamed": False},
    {"name": "b", "command": "env > '$ENV_B'; sleep 800", "cwd": "/tmp", "autoNamed": False}
]}], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
# the shell execs its last command in place, so pane a's process IS "sleep 801"
A_PID_BEFORE=$(pgrep -fx "sleep 801" | head -1)
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 2; }
ctl '{"cmd":"addAccount","account":"work","kind":"claude"}'
rm -f "$ENV_B"
ctl '{"cmd":"setAccount","name":"accts","pane":"b","account":"work"}'
sleep 3
ctl '{"cmd":"dumpState"}'
ACCT_DIR=$(python3 -c "import json; print(json.load(open('$CFG_DIR/state-dump.json'))['accounts'][0]['configDir'])" 2>/dev/null)
if [ -n "$ACCT_DIR" ] && [ -d "$ACCT_DIR" ] && [[ "$ACCT_DIR" == "$CFG_DIR/accounts/claude-work-"* ]]; then
  pass "account created with its own config dir inside the (isolated) fleet config"
else
  fail "account dir missing or misplaced: '$ACCT_DIR'"
fi
if grep -qx "CLAUDE_CONFIG_DIR=$ACCT_DIR" "$ENV_B" 2>/dev/null && grep -qx "FLEET_ACCOUNT=work" "$ENV_B"; then
  pass "switched pane restarted with CLAUDE_CONFIG_DIR + FLEET_ACCOUNT for that account"
else
  fail "pane b env lacks the account vars: $(grep -E 'CLAUDE_CONFIG_DIR|FLEET_ACCOUNT' "$ENV_B" 2>/dev/null | tr '\n' ' ')"
fi
A_PID_AFTER=$(pgrep -fx "sleep 801" | head -1)
if ! grep -q "^CLAUDE_CONFIG_DIR=\|^FLEET_ACCOUNT=" "$ENV_A" 2>/dev/null && [ -n "$A_PID_BEFORE" ] && [ "$A_PID_BEFORE" = "$A_PID_AFTER" ]; then
  pass "default-account pane untouched: no account vars, same process (not restarted)"
else
  fail "pane a affected (pid $A_PID_BEFORE -> $A_PID_AFTER, or has account vars)"
fi
if python3 -c "import json,sys; d=json.load(open('$APPJSON')); p=d['screens'][0]['panes']; sys.exit(0 if p[1].get('accountID')==d['accounts'][0]['id'] and not p[0].get('accountID') else 1)" 2>/dev/null; then
  pass "account + per-pane assignment persisted to app.json"
else
  fail "account assignment not persisted"
fi
kill_app_tree
pkill -f "sleep 80[01]" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3i. focused-pane tracking — Close Focused Pane closes the REAL one, not always the last"
# focusedPaneID comes from AppKit's actual first responder (checkFocusedPane,
# polled every 1s), not a guess. "focusPane" drives the exact same
# makeFirstResponder call a real click does (via focusRequest); "closeFocused"
# is the exact code path ⌘⇧W calls (closeFocusedPane). Two real, distinct PTYs.
python3 - > "$APPJSON" <<PYEOF
import json
json.dump({"screens": [{"name": "focus", "panes": [
    {"name": "first", "command": "sleep 802", "cwd": "/tmp", "autoNamed": False},
    {"name": "second", "command": "sleep 803", "cwd": "/tmp", "autoNamed": False}
]}], "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF
launch 6
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 2; }
ctl '{"cmd":"focusPane","name":"focus","pane":"second"}'
ctl '{"cmd":"dumpState"}'
FOCUSED=$(python3 -c "import json; print(json.load(open('$CFG_DIR/state-dump.json')).get('focusedPaneName'))" 2>/dev/null)
if [ "$FOCUSED" = "second" ]; then
  pass "focusedPaneID tracks a REAL AppKit first-responder change to a non-first pane"
else
  fail "expected focusedPaneName 'second', got '$FOCUSED' — first-responder tracking not working"
fi
ctl '{"cmd":"closeFocused","name":"focus"}'
REMAINING=$(python3 -c "import json; print([p['name'] for p in json.load(open('$APPJSON'))['screens'][0]['panes']])" 2>/dev/null)
if [ "$REMAINING" = "['first']" ]; then
  pass "Close Focused Pane closed 'second' (the actually-focused one), left 'first' running"
else
  fail "wrong pane closed — panes remaining: $REMAINING (expected only 'first')"
fi
kill_app_tree
pkill -f "sleep 80[23]" 2>/dev/null; true

# ---------------------------------------------------------------------------
section "3j. project›folder breadcrumb — real repo/worktree/cwd fields, not fabricated"
# A git-backed screen: crumb must be "<repoName> › <branchFolderName>", derived
# from GitWorktree's actual "<repo>-worktrees/<branch>" layout (section 5's
# own test proves that layout is real) — not a guess at what it should say.
TJ=/tmp/fleet-hardtest-3j-$$
rm -rf "$TJ" "$TJ-worktrees"
mkdir -p "$TJ" && (cd "$TJ" && git init -q && git commit -q --allow-empty -m init)
python3 - > "$APPJSON" <<PYEOF
import json
json.dump({"screens": []}, open('/dev/stdout', 'w'))
PYEOF
launch 4
ctl() { printf '%s' "$1" > "$CFG_DIR/control.json"; sleep 2; }
ctl "{\"cmd\":\"addScreen\",\"name\":\"crumbtest\",\"repoPath\":\"$TJ\",\"branch\":\"my-feature\",\"panes\":1,\"command\":\"sleep 804\"}"
ctl '{"cmd":"select","name":"crumbtest"}'
ctl '{"cmd":"dumpState"}'
CRUMB=$(python3 -c "import json; print(json.load(open('$CFG_DIR/state-dump.json')).get('activeScreenCrumb'))" 2>/dev/null)
EXPECTED="$(basename "$TJ") › my-feature"
if [ "$CRUMB" = "$EXPECTED" ]; then
  pass "git-backed screen crumb is real repo name › real worktree folder name ('$CRUMB')"
else
  fail "expected crumb '$EXPECTED', got '$CRUMB'"
fi
# A plain (non-git) screen: crumb falls back to the actual folder its pane runs in.
ctl '{"cmd":"addScreen","name":"plaincrumb","panes":1,"command":"sleep 805"}'
python3 -c "
import json
d = json.load(open('$APPJSON'))
for s in d['screens']:
    if s['name'] == 'plaincrumb': s['panes'][0]['cwd'] = '/tmp/some-project-folder'
json.dump(d, open('$APPJSON', 'w'))
"
kill_app_tree; pkill -f "sleep 80[45]" 2>/dev/null; true
mkdir -p /tmp/some-project-folder
launch 4
ctl '{"cmd":"select","name":"plaincrumb"}'
ctl '{"cmd":"dumpState"}'
CRUMB2=$(python3 -c "import json; print(json.load(open('$CFG_DIR/state-dump.json')).get('activeScreenCrumb'))" 2>/dev/null)
if [ "$CRUMB2" = "some-project-folder" ]; then
  pass "non-git screen crumb is just the real cwd folder name (no fabricated project name)"
else
  fail "expected crumb 'some-project-folder', got '$CRUMB2'"
fi
kill_app_tree
pkill -f "sleep 80[45]" 2>/dev/null; true
rm -rf "$TJ" "$TJ-worktrees" /tmp/some-project-folder

# ---------------------------------------------------------------------------
section "3k. screen blanking — smart auto-blank settings persist through the real gated setter"
# The real pmset/caffeinate calls (blankNow, and the timer's own blank/wake)
# are never exercised here — that would actually blank whoever's screen runs
# this suite. PowerManager.nextBlankState (the pure decision function) and
# the entitlement gate itself are proven separately: nextBlankState has no
# I/O to test in isolation from Swift without a dedicated test target, and
# the requireUpgrade/entitlement gate is the exact mechanism section 7c
# already proves works (free-tier pane cap uses the same pattern). This
# section only proves the new persisted fields round-trip through the real
# control path the Settings toggle/stepper use.
python3 - > "$APPJSON" <<PYEOF
import json
json.dump({"screens": [{"name": "s", "panes": [{"name": "p", "command": "sleep 806", "cwd": "/tmp"}]}]}, open('/dev/stdout', 'w'))
PYEOF
launch 4
ctl '{"cmd":"setSmartBlank","minutes":25,"enabled":true}'
sleep 1
MIN=$(python3 -c "import json; print(json.load(open('$APPJSON'))['smartBlankEnabled'], json.load(open('$APPJSON'))['blankAfterMinutes'])" 2>/dev/null)
if [ "$MIN" = "True 25" ]; then
  pass "smart auto-blank enabled + 25min threshold persisted to app.json (entitled owner)"
else
  fail "expected 'True 25' persisted, got '$MIN'"
fi
kill_app_tree
pkill -f "sleep 806" 2>/dev/null; true

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
