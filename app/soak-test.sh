#!/bin/bash
# Long-running soak: a separate Fleet instance with 16 synthetic panes, logging
# RSS / CPU / open FDs / child count to /tmp/fleet-soak-log.csv.
#
# It runs in its OWN config directory and its own app instance (open -n), so it
# never touches your real ~/.config/fleet or your running Fleet. Note it holds a
# "Display on" power assertion while it runs — stop it when you're done:
#
#   nohup ./soak-test.sh > /tmp/fleet-soak.out 2>&1 &     # start
#   tail -20 /tmp/fleet-soak-log.csv                       # check in later
#   ./soak-test.sh stop                                    # stop it and clean up
#
# SOAK_INTERVAL=seconds between samples (default 300).
set -uo pipefail
cd "$(dirname "$0")"
PIDFILE=/tmp/fleet-soak.pid          # the soak Fleet instance
SCRIPTPID=/tmp/fleet-soak-script.pid  # this script
if [ "${1:-}" = "stop" ]; then
  for f in "$PIDFILE" "$SCRIPTPID"; do [ -f "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
  pkill -f "FLEET_SOAK" 2>/dev/null   # the synthetic pane loops
  echo "soak stopped"; exit 0
fi
echo $$ > "$SCRIPTPID"
CFG=/tmp/fleet-soak-cfg
LOG=/tmp/fleet-soak-log.csv
INTERVAL=${SOAK_INTERVAL:-300}
rm -rf "$CFG"; mkdir -p "$CFG/fleet"
touch "$CFG/fleet/owner"          # entitled, so all 16 panes run
python3 - > "$CFG/fleet/app.json" <<'PYEOF'
import json
screens = [{"name": f"s{i}", "panes": [
    {"name": f"p{j}", "command": "i=0; while true; do i=$((i+1)); echo tick $i $(date); sleep 3; done # FLEET_SOAK", "cwd": "/tmp"}
    for j in range(4)]} for i in range(4)]
json.dump({"screens": screens, "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF

before=$(pgrep -f 'Fleet.app/Contents/MacOS/Fleet' | sort)
open -n --env XDG_CONFIG_HOME="$CFG" Fleet.app
sleep 6
APP=""
for p in $(pgrep -f 'Fleet.app/Contents/MacOS/Fleet'); do
  echo "$before" | grep -qx "$p" || APP=$p
done
[ -z "$APP" ] && { echo "could not find the soak instance"; exit 1; }
echo "$APP" > "$PIDFILE"
echo "soak instance pid $APP, config $CFG, sampling every ${INTERVAL}s"

echo "timestamp,elapsed_min,rss_mb,cpu_pct,fd_count,child_count" > "$LOG"
START=$(date +%s)
trap 'kill -9 "$APP" 2>/dev/null; pkill -f "FLEET_SOAK" 2>/dev/null; rm -f "$PIDFILE" "$SCRIPTPID"; exit 0' INT TERM
while true; do
  if ! kill -0 "$APP" 2>/dev/null; then echo "$(date -u +%FT%TZ),CRASHED — soak instance is gone" >> "$LOG"; break; fi
  ELAPSED=$(( ($(date +%s) - START) / 60 ))
  RSS=$(ps -axo pid,ppid,rss | awk -v a="$APP" '$1==a || $2==a {s+=$3} END{printf "%.0f", s/1024}')
  CPU=$(ps -axo pid,ppid,%cpu | awk -v a="$APP" '$1==a || $2==a {s+=$3} END{printf "%.1f", s}')
  FDS=$(lsof -p "$APP" 2>/dev/null | wc -l | tr -d ' ')
  KIDS=$(ps -axo pid,ppid | awk -v a="$APP" '$2==a' | wc -l | tr -d ' ')
  echo "$(date -u +%FT%TZ),$ELAPSED,$RSS,$CPU,$FDS,$KIDS" >> "$LOG"
  sleep "$INTERVAL"
done
