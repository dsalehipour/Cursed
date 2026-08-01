#!/usr/bin/env bash
# Starts cursed automatically at login via a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/cursed.app/Contents/MacOS/cursed"
PLIST="$HOME/Library/LaunchAgents/com.cursed.app.plist"

[ -x "$APP" ] || { echo "not built yet; run scripts/build.sh"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.cursed.app</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>StandardErrorPath</key>
	<string>$ROOT/build/cursed.log</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "installed login item: $PLIST"
echo "remove with: scripts/uninstall-login-item.sh"
