#!/bin/bash
# Build PCOSync.app into build/. Needs Xcode or the Command Line Tools
# (xcode-select --install). No Apple developer account needed.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Command Line Tools first:  xcode-select --install" >&2
  exit 1
fi

echo "==> Building (release)…"
swift build -c release --product PCOSync
BIN="$(swift build -c release --show-bin-path)/PCOSync"

APP=build/PCOSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PCOSync"
cp macos/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for a locally built app to run and to register
# as a login item. Not notarized, so it's for this Mac (or ones you copy it to).
codesign --force --sign - "$APP"
echo "==> Built $APP"
