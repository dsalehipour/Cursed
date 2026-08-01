#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/cursed.app"

echo "==> building release binary"
swift build -c release

# Replacing the bundle underneath a running copy can kill it, so stop it first.
"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true

echo "==> assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/cursed" "$APP/Contents/MacOS/cursed"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>cursed</string>
	<key>CFBundleIdentifier</key>
	<string>com.cursed.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>cursed</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

# Ad-hoc is enough here: the app reads only files the user already owns. Accessibility (used
# for the best-effort window raise) is optional, and its grant is pinned to the cdhash, so it
# needs re-approving after a rebuild.
codesign --force --sign - --identifier com.cursed.app "$APP"
codesign --verify --verbose=1 "$APP"

echo
echo "built $APP"
echo "run: scripts/run.sh"
