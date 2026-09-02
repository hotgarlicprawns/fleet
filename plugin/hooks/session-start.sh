#!/bin/sh
# fleet — keep this Mac awake for the duration of the Claude Code session.
# Honours ~/.config/fleet/config.json power.mode. Safe no-op off macOS.
[ "$(uname)" = "Darwin" ] || exit 0

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/config.json"
MODE="awake-blank"
if [ -f "$CFG" ] && command -v /usr/bin/plutil >/dev/null 2>&1; then
  M=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$CFG')).get('power',{}).get('mode','awake-blank'))" 2>/dev/null)
  [ -n "$M" ] && MODE="$M"
fi

# only auto-manage if fleet isn't already holding a lock
STATE="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/state.json"
[ -f "$STATE" ] && grep -q caffeinatePid "$STATE" && exit 0

case "$MODE" in
  off) exit 0 ;;
  awake-on)    FLAGS="-d -i -s" ;;
  prevent-all) FLAGS="-d -i -m -s" ;;
  *)           FLAGS="-i -s" ;;   # awake-blank
esac

# shellcheck disable=SC2086
nohup caffeinate $FLAGS >/dev/null 2>&1 &
echo "{\"caffeinatePid\": $!, \"powerMode\": \"$MODE\", \"startedAt\": \"$(date -u +%FT%TZ)\", \"owner\": \"hook\"}" > "$STATE"

if [ "$MODE" = "awake-blank" ]; then
  ( sleep 2; pmset displaysleepnow ) >/dev/null 2>&1 &
fi
exit 0
