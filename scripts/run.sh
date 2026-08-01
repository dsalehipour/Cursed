#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/cursed.app"

[ -d "$APP" ] || { echo "not built yet; run scripts/build.sh"; exit 1; }

"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true

# Launch through LaunchServices so the app belongs to launchd rather than this shell,
# which is what keeps it alive after the terminal session goes away.
open "$APP"
sleep 1

if pgrep -x cursed >/dev/null 2>&1; then
  echo "cursed running (pid $(pgrep -x cursed | head -1))"
  echo "log: ~/Library/Logs/cursed.log"
  echo "stop: scripts/stop.sh"
else
  echo "cursed failed to start; see ~/Library/Logs/cursed.log"
  exit 1
fi
