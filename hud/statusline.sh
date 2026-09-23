#!/bin/sh
# fleet HUD — Claude Code statusLine script.
# 1. renders a status line (model · context · cost · rate limits)
# 2. writes a JSON sidecar per session so `fleet` can show live stats
#    on every tmux pane border and aggregate spend in `fleet report`.
#
# Wire it in with:  fleet hud install   (edits ~/.claude/settings.json)

input=$(cat)
SESS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/sessions"
mkdir -p "$SESS_DIR" 2>/dev/null

# --- extract (jq if present, else python) ---
if command -v jq >/dev/null 2>&1; then
  get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
  model=$(get '.model.display_name')
  ctx=$(get '.context_window.used_percentage')
  cost=$(get '.cost.total_cost_usd')
  added=$(get '.cost.total_lines_added')
  removed=$(get '.cost.total_lines_removed')
  five=$(get '.rate_limits.five_hour.used_percentage')
  week=$(get '.rate_limits.seven_day.used_percentage')
  sid=$(get '.session_id')
  dir=$(get '.workspace.current_dir'); [ -z "$dir" ] && dir=$(get '.cwd')
else
  eval "$(printf '%s' "$input" | /usr/bin/python3 -c '
import sys,json
d=json.load(sys.stdin)
def g(*ks):
    x=d
    for k in ks:
        x=x.get(k) if isinstance(x,dict) else None
    return "" if x is None else x
print("model=%r"%str(g("model","display_name") or "Claude"))
print("ctx=%r"%str(g("context_window","used_percentage")))
print("cost=%r"%str(g("cost","total_cost_usd")))
print("added=%r"%str(g("cost","total_lines_added")))
print("removed=%r"%str(g("cost","total_lines_removed")))
print("five=%r"%str(g("rate_limits","five_hour","used_percentage")))
print("week=%r"%str(g("rate_limits","seven_day","used_percentage")))
print("sid=%r"%str(g("session_id")))
print("dir=%r"%str(g("workspace","current_dir") or g("cwd")))
')"
fi

now=$(date +%s)
[ -z "$sid" ] && sid="unknown-$$"
f="$SESS_DIR/$sid.json"

# preserve attention/state flags written by the Notification / Stop hooks
att=false; state=working; first=$now
if [ -f "$f" ]; then
  prev=$(cat "$f")
  case "$prev" in *'"attention": true'*) att=true ;; esac
  st=$(printf '%s' "$prev" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p'); [ -n "$st" ] && state=$st
  fs=$(printf '%s' "$prev" | sed -n 's/.*"firstSeen": \([0-9]*\).*/\1/p'); [ -n "$fs" ] && first=$fs
fi
# a fresh statusline render means Claude is doing something -> not waiting
[ "$state" = "waiting" ] && state=working && att=false

realdir=$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")
ci() { printf '%s' "${1:-0}" | awk '{printf "%d", $1+0}'; }
cf() { printf '%s' "${1:-0}" | awk '{printf "%.4f", $1+0}'; }
# For the JSON sidecar specifically: emit literal `null` for missing data
# instead of 0. A brand-new session has no rate_limits yet (Claude Code
# hasn't gotten a response with that data back), and the old `ci`/`cf`
# (defaulting to 0) wrote a real "0" into the sidecar — indistinguishable
# from "this account has genuinely used 0% of its rate limit." Fleet then
# showed "5h 0% · 7d 0%" on a pane that had simply never reported yet, which
# reads as wrong/stale data rather than "no data available."
cin() { if [ -z "$1" ] || [ "$1" = "null" ]; then printf 'null'; else ci "$1"; fi; }
cfn() { if [ -z "$1" ] || [ "$1" = "null" ]; then printf 'null'; else cf "$1"; fi; }

cat > "$f" <<EOF
{
  "sessionId": "$sid",
  "claudePid": ${PPID:-0},
  "hudVersion": 2,
  "fleetPaneId": "${FLEET_PANE_ID:-}",
  "account": "${FLEET_ACCOUNT:-}",
  "configDir": "${CLAUDE_CONFIG_DIR:-}",
  "dir": "$realdir",
  "model": "${model:-Claude}",
  "costUsd": $(cfn "$cost"),
  "ctxPct": $(cin "$ctx"),
  "rl5h": $(cin "$five"),
  "rl7d": $(cin "$week"),
  "linesAdded": $(ci "$added"),
  "linesRemoved": $(ci "$removed"),
  "attention": $att,
  "state": "$state",
  "firstSeen": $first,
  "updated": $now
}
EOF

# --- render the status line for the user ---
DIM='\033[2m'; RST='\033[0m'; B='\033[1m'
out="${B}${model:-Claude}${RST}"
if [ -n "$ctx" ]; then
  ci_v=$(ci "$ctx"); w=10; fill=$(( ci_v * w / 100 )); [ $fill -gt $w ] && fill=$w
  bar=$(printf '%*s' "$fill" '' | tr ' ' '#')$(printf '%*s' $((w-fill)) '' | tr ' ' '-')
  out="$out  ${DIM}ctx [${bar}] ${ci_v}%${RST}"
fi
[ -n "$cost" ] && [ "$cost" != "null" ] && out="$out  ${DIM}$(printf '$%.2f' "$cost")${RST}"
[ -n "$five" ] && out="$out  ${DIM}5h:$(ci "$five")%${RST}"
[ -n "$week" ] && out="$out ${DIM}7d:$(ci "$week")%${RST}"

# --- fleet-lean: real, code-computed tokens-avoided for THIS session ---
# Correlates by claudePid ($PPID here, process.ppid in the fleet-lean MCP
# server — both are direct children of the same top-level `claude` process
# for this session, verified empirically). Only sums sidecars matching that
# PID, so this never shows another pane's numbers — the old "most recently
# modified sidecar" heuristic in /fleet-lean-report could and did.
lean_tok=0
if [ -n "${PPID:-}" ] && [ -d "$SESS_DIR" ]; then
  if command -v jq >/dev/null 2>&1; then
    for lf in "$SESS_DIR"/*.lean.json; do
      [ -e "$lf" ] || continue
      cp=$(jq -r '.claudePid // empty' "$lf" 2>/dev/null)
      [ "$cp" = "$PPID" ] || continue
      sum=$(jq '[.calls[].estTokensAvoided // 0] | add // 0' "$lf" 2>/dev/null)
      lean_tok=$((lean_tok + ${sum:-0}))
    done
  elif command -v /usr/bin/python3 >/dev/null 2>&1; then
    lean_tok=$(/usr/bin/python3 -c "
import glob, json, os
total = 0
for path in glob.glob(os.path.join('$SESS_DIR', '*.lean.json')):
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if str(d.get('claudePid')) != '$PPID':
        continue
    total += sum(c.get('estTokensAvoided', 0) for c in d.get('calls', []))
print(total)
" 2>/dev/null)
    [ -z "$lean_tok" ] && lean_tok=0
  fi
fi
if [ "${lean_tok:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$lean_tok" -ge 1000 ]; then
    lean_disp=$(awk -v t="$lean_tok" 'BEGIN{printf "%.1fk", t/1000}')
  else
    lean_disp="$lean_tok"
  fi
  out="$out  ${DIM}lean ↓${lean_disp} tok (est.)${RST}"
fi

printf "%b\n" "$out"
