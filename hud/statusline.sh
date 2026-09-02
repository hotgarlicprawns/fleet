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

cat > "$f" <<EOF
{
  "sessionId": "$sid",
  "dir": "$realdir",
  "model": "${model:-Claude}",
  "costUsd": $(cf "$cost"),
  "ctxPct": $(ci "$ctx"),
  "rl5h": $(ci "$five"),
  "rl7d": $(ci "$week"),
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
printf "%b\n" "$out"
