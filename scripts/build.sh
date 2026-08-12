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
# Committed rather than built here: it changes only when the artwork does, and generating it needs
# the source art. After editing assets/icon.png, regenerate both things derived from it:
#   swift scripts/make-icon.swift assets/icon.png Resources/cursed.icns
#   swift scripts/make-icon.swift assets/icon.png assets/icon-rounded.png 384   # for the README
cp "$ROOT/Resources/cursed.icns" "$APP/Contents/Resources/cursed.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>cursed</string>
	<key>CFBundleIconFile</key>
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
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

# Signed with a fixed local identity rather than ad-hoc. Clicking a row needs Accessibility, and
# macOS pins that grant to the signature: an ad-hoc signature is derived from the code hash and
# so changes with every build, which silently revoked the permission each time. Ad-hoc is kept as
# a fallback so the project still builds without the certificate.
IDENTITY="cursed-dev"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier com.cursed.app "$APP"
else
    echo "==> no '$IDENTITY' identity found, signing ad-hoc; Accessibility will need"
    echo "    re-approving after every build. Run scripts/create-signing-identity.sh once."
    codesign --force --sign - --identifier com.cursed.app "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo
echo "built $APP"
echo "run: scripts/run.sh"
