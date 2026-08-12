#!/usr/bin/env bash
# Publishes the built app as a GitHub release, so it can be downloaded and run without a clone.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/cursed.app"
# The same name every release, which is what makes /releases/latest/download/cursed.zip a link
# that never needs updating. The version is carried by the tag and the title instead.
ZIP="$ROOT/build/cursed.zip"

command -v gh >/dev/null || { echo "needs the GitHub CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "not logged in; run gh auth login"; exit 1; }

# A release is a claim that this tag builds this app, so both halves have to be true: nothing
# uncommitted in the build, and a commit the remote can actually hang the tag on.
git diff --quiet && git diff --cached --quiet \
    || { echo "uncommitted changes; commit them first"; exit 1; }
git fetch -q origin
git merge-base --is-ancestor HEAD origin/main \
    || { echo "HEAD is not on origin/main yet; push first"; exit 1; }

# Releasing should not leave your own panel shut, and building replaces the bundle underneath it.
WAS_RUNNING=$(pgrep -x cursed >/dev/null 2>&1 && echo yes || echo no)

"$ROOT/scripts/build.sh"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "$TAG is already released; bump CFBundleShortVersionString in scripts/build.sh first"
    exit 1
fi

echo "==> packaging $TAG"
rm -f "$ZIP"
# ditto rather than zip, which is the difference between a signature that survives the round trip
# and one that does not. A broken one costs the downloader their Accessibility grant.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Unpacked and checked here rather than by whoever downloads it first.
UNPACKED=$(mktemp -d)
trap 'rm -rf "$UNPACKED"' EXIT
ditto -x -k "$ZIP" "$UNPACKED"
codesign --verify --strict "$UNPACKED/cursed.app"

echo "==> publishing $TAG"
gh release create "$TAG" "$ZIP" --title "cursed $VERSION" --notes "$(cat <<'NOTES'
Apple Silicon, macOS 26 or later. Cursor, the ChatGPT Mac app, and Claude Code (Desktop or CLI)
are all optional — the panel reads whichever of them is there.

### Install

1. Download `cursed.zip` below, unzip it, and drag `cursed.app` to Applications.
2. Open it. macOS refuses the first time: the app is signed, but not notarized by Apple.
3. Go to **System Settings › Privacy & Security**, scroll to Security, and click **Open Anyway**.
   The button only appears for about an hour after the refusal. Then open the app again.
4. Clicking a row brings that conversation forward in Cursor, which macOS only allows through
   **System Settings › Privacy & Security › Accessibility**. Everything else works without it.

There is no dock icon and no window: the floating list is the whole app. Drag it anywhere, and
quit from its menu bar item.
NOTES
)"

if [ "$WAS_RUNNING" = yes ]; then "$ROOT/scripts/run.sh" >/dev/null; fi

echo
echo "released $TAG"
echo "always-latest link: https://github.com/dsalehipour/Cursed/releases/latest/download/cursed.zip"
