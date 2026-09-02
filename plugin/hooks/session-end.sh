#!/bin/sh
# fleet — release the awake-lock when the Claude Code session ends,
# but only if this hook is the one that took it.
[ "$(uname)" = "Darwin" ] || exit 0

STATE="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/state.json"
[ -f "$STATE" ] || exit 0
grep -q '"owner": "hook"' "$STATE" || exit 0

PID=$(/usr/bin/python3 -c "import json;print(json.load(open('$STATE')).get('caffeinatePid',''))" 2>/dev/null)
[ -n "$PID" ] && kill "$PID" 2>/dev/null
rm -f "$STATE"
exit 0
