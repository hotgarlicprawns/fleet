#!/bin/sh
# fleet — mark a session as waiting-for-you (Notification) or done (Stop).
# Argument $1: "waiting" | "idle"
STATE="${1:-idle}"
SESS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/sessions"
mkdir -p "$SESS_DIR" 2>/dev/null

input=$(cat 2>/dev/null)
sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[ :]*"\([^"]*\)".*/\1/p')
[ -z "$sid" ] && sid=$(printf '%s' "$input" | sed -n 's/.*"sessionId"[ :]*"\([^"]*\)".*/\1/p')
[ -z "$sid" ] && exit 0
dir=$(printf '%s' "$input" | sed -n 's/.*"cwd"[ :]*"\([^"]*\)".*/\1/p')
f="$SESS_DIR/$sid.json"
now=$(date +%s)

att=false; [ "$STATE" = "waiting" ] && att=true
if [ -f "$f" ]; then
  /usr/bin/python3 - "$f" "$STATE" "$att" "$now" <<'EOF' 2>/dev/null
import json,sys
f,state,att,now=sys.argv[1:5]
try: d=json.load(open(f))
except: d={}
d["state"]=state; d["attention"]=(att=="true"); d["updated"]=int(now)
json.dump(d,open(f,"w"),indent=2)
EOF
else
  cat > "$f" <<EOF
{ "sessionId": "$sid", "dir": "$dir", "state": "$STATE", "attention": $att, "firstSeen": $now, "updated": $now, "costUsd": 0, "ctxPct": 0 }
EOF
fi
exit 0
