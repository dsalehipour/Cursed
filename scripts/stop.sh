#!/usr/bin/env bash
set -euo pipefail
if pkill -f "cursed.app/Contents/MacOS/cursed"; then
  echo "stopped cursed"
else
  echo "cursed was not running"
fi
