#!/bin/bash
# Long-running soak test: launches Fleet.app with a moderate synthetic load
# and logs total RSS/CPU/FD count every 5 minutes. Meant to run for hours —
# start it with nohup and check the log later (this is the "leave it running
# overnight" check from TESTING.md that can't be done in one sitting).
#
#   nohup ./soak-test.sh > /tmp/fleet-soak.out 2>&1 &
#   disown
#   # ... hours later ...
#   tail -50 /tmp/fleet-soak-log.csv
set -uo pipefail
cd "$(dirname "$0")"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleet"
LOG=/tmp/fleet-soak-log.csv

python3 - > "$CFG_DIR/app.json" <<'PYEOF'
import json
screens = [{"name": f"s{i}", "panes": [
    {"name": f"p{j}", "command": "i=0; while true; do i=$((i+1)); echo tick $i $(date); sleep 3; done", "cwd": "/tmp"}
    for j in range(4)
]} for i in range(4)]
json.dump({"screens": screens, "power": "Display on"}, open('/dev/stdout', 'w'))
PYEOF

pkill -f "Fleet.app/Contents/MacOS/Fleet" 2>/dev/null; sleep 1
open Fleet.app
sleep 5

echo "timestamp,elapsed_min,rss_mb,cpu_pct,fd_count,child_count" > "$LOG"
START=$(date +%s)
while true; do
  APP=$(ps -axo pid,command | awk '/Fleet\.app\/Contents\/MacOS\/Fleet/ && !/awk/ {print $1; exit}')
  if [ -z "$APP" ]; then
    echo "$(date -u +%FT%TZ),CRASHED — app no longer running" >> "$LOG"
    break
  fi
  ELAPSED=$(( ($(date +%s) - START) / 60 ))
  RSS=$(ps -axo pid,ppid,rss | awk -v a="$APP" '$1==a || $2==a {s+=$3} END{printf "%.0f", s/1024}')
  CPU=$(ps -axo pid,ppid,%cpu | awk -v a="$APP" '$1==a || $2==a {s+=$3} END{printf "%.1f", s}')
  FDS=$(lsof -p "$APP" 2>/dev/null | wc -l | tr -d ' ')
  KIDS=$(ps -axo pid,ppid | awk -v a="$APP" '$2==a' | wc -l | tr -d ' ')
  echo "$(date -u +%FT%TZ),$ELAPSED,$RSS,$CPU,$FDS,$KIDS" >> "$LOG"
  sleep 300
done
