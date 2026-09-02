#!/bin/sh
# fleet — keep this Mac awake for the duration of the Claude Code session.
# Honours ~/.config/fleet/config.json power.mode. Safe no-op off macOS.
[ "$(uname)" = "Darwin" ] || exit 0

mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/fleet/sessions" 2>/dev/null
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
  awake-blank) FLAGS="-i -s" ;;    # system awake, display follows macOS setting
  prevent-all) FLAGS="-d -i -m -s" ;;
  *)           FLAGS="-d -i -s" ;;  # awake-on (default) — display stays on
esac

# shellcheck disable=SC2086
nohup caffeinate $FLAGS >/dev/null 2>&1 &
echo "{\"caffeinatePid\": $!, \"powerMode\": \"$MODE\", \"startedAt\": \"$(date -u +%FT%TZ)\", \"owner\": \"hook\"}" > "$STATE"
# the hook never blanks the screen — that is only ever `fleet blank` / `fleet watch`.
exit 0
